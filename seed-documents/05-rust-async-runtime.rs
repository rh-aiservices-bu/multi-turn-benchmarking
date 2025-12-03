use std::collections::{BinaryHeap, HashMap, VecDeque};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, RwLock};
use std::task::{Context, Poll, RawWaker, RawWakerVTable, Waker};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// A unique identifier for each task in the runtime
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TaskId(usize);

impl TaskId {
    fn new() -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        TaskId(COUNTER.fetch_add(1, Ordering::Relaxed))
    }
}

/// Priority levels for task scheduling
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Priority {
    Low = 0,
    Normal = 1,
    High = 2,
    Critical = 3,
}

impl Default for Priority {
    fn default() -> Self {
        Priority::Normal
    }
}

/// A boxed future that can be sent across threads
type BoxedFuture = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

/// Represents a task that can be executed by the runtime
struct Task {
    id: TaskId,
    future: Mutex<Option<BoxedFuture>>,
    priority: Priority,
    created_at: Instant,
    state: AtomicTaskState,
}

/// Atomic task state for lock-free state transitions
struct AtomicTaskState {
    inner: AtomicUsize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(usize)]
enum TaskState {
    Pending = 0,
    Running = 1,
    Waiting = 2,
    Completed = 3,
    Cancelled = 4,
}

impl AtomicTaskState {
    fn new(state: TaskState) -> Self {
        Self {
            inner: AtomicUsize::new(state as usize),
        }
    }

    fn load(&self) -> TaskState {
        match self.inner.load(Ordering::SeqCst) {
            0 => TaskState::Pending,
            1 => TaskState::Running,
            2 => TaskState::Waiting,
            3 => TaskState::Completed,
            4 => TaskState::Cancelled,
            _ => unreachable!(),
        }
    }

    fn store(&self, state: TaskState) {
        self.inner.store(state as usize, Ordering::SeqCst);
    }

    fn compare_exchange(&self, current: TaskState, new: TaskState) -> Result<TaskState, TaskState> {
        self.inner
            .compare_exchange(
                current as usize,
                new as usize,
                Ordering::SeqCst,
                Ordering::SeqCst,
            )
            .map(|v| match v {
                0 => TaskState::Pending,
                1 => TaskState::Running,
                2 => TaskState::Waiting,
                3 => TaskState::Completed,
                4 => TaskState::Cancelled,
                _ => unreachable!(),
            })
            .map_err(|v| match v {
                0 => TaskState::Pending,
                1 => TaskState::Running,
                2 => TaskState::Waiting,
                3 => TaskState::Completed,
                4 => TaskState::Cancelled,
                _ => unreachable!(),
            })
    }
}

impl Task {
    fn new<F>(future: F, priority: Priority) -> Arc<Self>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        Arc::new(Task {
            id: TaskId::new(),
            future: Mutex::new(Some(Box::pin(future))),
            priority,
            created_at: Instant::now(),
            state: AtomicTaskState::new(TaskState::Pending),
        })
    }
}

/// Entry in the priority queue for task scheduling
struct QueueEntry {
    task: Arc<Task>,
    scheduled_at: Instant,
}

impl PartialEq for QueueEntry {
    fn eq(&self, other: &Self) -> bool {
        self.task.id == other.task.id
    }
}

impl Eq for QueueEntry {}

impl PartialOrd for QueueEntry {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for QueueEntry {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        // Higher priority first, then earlier scheduled time
        match self.task.priority.cmp(&other.task.priority) {
            std::cmp::Ordering::Equal => other.scheduled_at.cmp(&self.scheduled_at),
            ord => ord,
        }
    }
}

/// Timer wheel for efficient timer management
struct TimerWheel {
    wheels: Vec<Vec<Vec<(Instant, Arc<Task>)>>>,
    current_tick: usize,
    tick_duration: Duration,
    last_tick: Instant,
}

impl TimerWheel {
    fn new(tick_duration: Duration, wheel_sizes: &[usize]) -> Self {
        let wheels = wheel_sizes
            .iter()
            .map(|&size| vec![Vec::new(); size])
            .collect();

        Self {
            wheels,
            current_tick: 0,
            tick_duration,
            last_tick: Instant::now(),
        }
    }

    fn schedule(&mut self, deadline: Instant, task: Arc<Task>) {
        let now = Instant::now();
        if deadline <= now {
            // Already expired, add to current slot
            self.wheels[0][self.current_tick % self.wheels[0].len()].push((deadline, task));
            return;
        }

        let ticks_away = (deadline - now).as_nanos() / self.tick_duration.as_nanos();
        let ticks_away = ticks_away as usize;

        // Find appropriate wheel level
        let mut remaining = ticks_away;
        for (level, wheel) in self.wheels.iter_mut().enumerate() {
            if remaining < wheel.len() {
                let slot = (self.current_tick + remaining) % wheel.len();
                wheel[slot].push((deadline, task));
                return;
            }
            remaining /= wheel.len();
        }

        // Too far in the future, add to last wheel's last slot
        let last_wheel = self.wheels.last_mut().unwrap();
        last_wheel[last_wheel.len() - 1].push((deadline, task));
    }

    fn advance(&mut self) -> Vec<Arc<Task>> {
        let mut ready = Vec::new();
        let now = Instant::now();

        while self.last_tick + self.tick_duration <= now {
            self.last_tick += self.tick_duration;
            self.current_tick = self.current_tick.wrapping_add(1);

            // Cascade from higher wheels if necessary
            for level in 0..self.wheels.len() {
                let slot = self.current_tick % self.wheels[level].len();

                if slot == 0 && level < self.wheels.len() - 1 {
                    // Cascade entries from next level
                    let next_slot = (self.current_tick / self.wheels[level].len())
                        % self.wheels[level + 1].len();
                    let entries: Vec<_> = self.wheels[level + 1][next_slot].drain(..).collect();

                    for (deadline, task) in entries {
                        self.schedule(deadline, task);
                    }
                }

                // Collect ready tasks from current slot
                let entries: Vec<_> = self.wheels[level][slot].drain(..).collect();
                for (deadline, task) in entries {
                    if deadline <= now {
                        ready.push(task);
                    } else {
                        self.schedule(deadline, task);
                    }
                }
            }
        }

        ready
    }
}

/// Work-stealing deque for load balancing
struct WorkStealingDeque<T> {
    items: Mutex<VecDeque<T>>,
}

impl<T> WorkStealingDeque<T> {
    fn new() -> Self {
        Self {
            items: Mutex::new(VecDeque::new()),
        }
    }

    fn push_back(&self, item: T) {
        self.items.lock().unwrap().push_back(item);
    }

    fn pop_front(&self) -> Option<T> {
        self.items.lock().unwrap().pop_front()
    }

    fn steal(&self) -> Option<T> {
        self.items.lock().unwrap().pop_back()
    }

    fn len(&self) -> usize {
        self.items.lock().unwrap().len()
    }

    fn is_empty(&self) -> bool {
        self.items.lock().unwrap().is_empty()
    }
}

/// Configuration for the async runtime
#[derive(Clone, Debug)]
pub struct RuntimeConfig {
    pub num_workers: usize,
    pub stack_size: usize,
    pub enable_io: bool,
    pub timer_tick_duration: Duration,
    pub max_blocking_threads: usize,
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            num_workers: num_cpus::get(),
            stack_size: 2 * 1024 * 1024, // 2 MB
            enable_io: true,
            timer_tick_duration: Duration::from_millis(1),
            max_blocking_threads: 512,
        }
    }
}

/// Statistics about runtime operation
#[derive(Clone, Debug, Default)]
pub struct RuntimeStats {
    pub tasks_spawned: AtomicUsize,
    pub tasks_completed: AtomicUsize,
    pub tasks_cancelled: AtomicUsize,
    pub poll_count: AtomicUsize,
    pub steal_count: AtomicUsize,
    pub timer_fires: AtomicUsize,
}

/// The main async runtime structure
pub struct Runtime {
    config: RuntimeConfig,
    workers: Vec<Worker>,
    global_queue: Arc<WorkStealingDeque<Arc<Task>>>,
    timer_wheel: Arc<Mutex<TimerWheel>>,
    task_registry: Arc<RwLock<HashMap<TaskId, Arc<Task>>>>,
    shutdown: Arc<AtomicBool>,
    stats: Arc<RuntimeStats>,
    condvar: Arc<(Mutex<bool>, Condvar)>,
}

struct Worker {
    id: usize,
    handle: Option<JoinHandle<()>>,
    local_queue: Arc<WorkStealingDeque<Arc<Task>>>,
}

impl Runtime {
    /// Create a new runtime with the given configuration
    pub fn new(config: RuntimeConfig) -> Self {
        let global_queue = Arc::new(WorkStealingDeque::new());
        let timer_wheel = Arc::new(Mutex::new(TimerWheel::new(
            config.timer_tick_duration,
            &[256, 64, 64], // 3-level timer wheel
        )));
        let task_registry = Arc::new(RwLock::new(HashMap::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let stats = Arc::new(RuntimeStats::default());
        let condvar = Arc::new((Mutex::new(false), Condvar::new()));

        let workers = (0..config.num_workers)
            .map(|id| Worker {
                id,
                handle: None,
                local_queue: Arc::new(WorkStealingDeque::new()),
            })
            .collect();

        Self {
            config,
            workers,
            global_queue,
            timer_wheel,
            task_registry,
            shutdown,
            stats,
            condvar,
        }
    }

    /// Spawn a new task with default priority
    pub fn spawn<F>(&self, future: F) -> TaskId
    where
        F: Future<Output = ()> + Send + 'static,
    {
        self.spawn_with_priority(future, Priority::Normal)
    }

    /// Spawn a new task with the specified priority
    pub fn spawn_with_priority<F>(&self, future: F, priority: Priority) -> TaskId
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let task = Task::new(future, priority);
        let id = task.id;

        self.task_registry.write().unwrap().insert(id, task.clone());
        self.global_queue.push_back(task);
        self.stats.tasks_spawned.fetch_add(1, Ordering::Relaxed);

        // Wake up a worker
        let (lock, cvar) = &*self.condvar;
        let mut notified = lock.lock().unwrap();
        *notified = true;
        cvar.notify_one();

        id
    }

    /// Schedule a task to run after a delay
    pub fn spawn_delayed<F>(&self, delay: Duration, future: F) -> TaskId
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let task = Task::new(future, Priority::Normal);
        let id = task.id;

        self.task_registry.write().unwrap().insert(id, task.clone());
        self.timer_wheel
            .lock()
            .unwrap()
            .schedule(Instant::now() + delay, task);

        id
    }

    /// Cancel a task by ID
    pub fn cancel(&self, task_id: TaskId) -> bool {
        if let Some(task) = self.task_registry.read().unwrap().get(&task_id) {
            if task
                .state
                .compare_exchange(TaskState::Pending, TaskState::Cancelled)
                .is_ok()
                || task
                    .state
                    .compare_exchange(TaskState::Waiting, TaskState::Cancelled)
                    .is_ok()
            {
                self.stats.tasks_cancelled.fetch_add(1, Ordering::Relaxed);
                return true;
            }
        }
        false
    }

    /// Start the runtime and all worker threads
    pub fn start(&mut self) {
        for worker in &mut self.workers {
            let global_queue = self.global_queue.clone();
            let local_queue = worker.local_queue.clone();
            let timer_wheel = self.timer_wheel.clone();
            let task_registry = self.task_registry.clone();
            let shutdown = self.shutdown.clone();
            let stats = self.stats.clone();
            let condvar = self.condvar.clone();
            let worker_id = worker.id;
            let all_local_queues: Vec<_> =
                self.workers.iter().map(|w| w.local_queue.clone()).collect();

            let handle = thread::Builder::new()
                .name(format!("worker-{}", worker_id))
                .stack_size(self.config.stack_size)
                .spawn(move || {
                    Self::worker_loop(
                        worker_id,
                        global_queue,
                        local_queue,
                        all_local_queues,
                        timer_wheel,
                        task_registry,
                        shutdown,
                        stats,
                        condvar,
                    );
                })
                .expect("Failed to spawn worker thread");

            worker.handle = Some(handle);
        }
    }

    fn worker_loop(
        worker_id: usize,
        global_queue: Arc<WorkStealingDeque<Arc<Task>>>,
        local_queue: Arc<WorkStealingDeque<Arc<Task>>>,
        all_local_queues: Vec<Arc<WorkStealingDeque<Arc<Task>>>>,
        timer_wheel: Arc<Mutex<TimerWheel>>,
        task_registry: Arc<RwLock<HashMap<TaskId, Arc<Task>>>>,
        shutdown: Arc<AtomicBool>,
        stats: Arc<RuntimeStats>,
        condvar: Arc<(Mutex<bool>, Condvar)>,
    ) {
        let mut rng_state = worker_id as u64;

        while !shutdown.load(Ordering::Relaxed) {
            // Process ready timers
            {
                let ready_tasks = timer_wheel.lock().unwrap().advance();
                for task in ready_tasks {
                    stats.timer_fires.fetch_add(1, Ordering::Relaxed);
                    local_queue.push_back(task);
                }
            }

            // Try to get a task from various sources
            let task = local_queue
                .pop_front()
                .or_else(|| global_queue.pop_front())
                .or_else(|| {
                    // Work stealing
                    let num_queues = all_local_queues.len();
                    for i in 0..num_queues {
                        // Simple xorshift random
                        rng_state ^= rng_state << 13;
                        rng_state ^= rng_state >> 17;
                        rng_state ^= rng_state << 5;
                        let target = (rng_state as usize) % num_queues;

                        if target != worker_id {
                            if let Some(task) = all_local_queues[target].steal() {
                                stats.steal_count.fetch_add(1, Ordering::Relaxed);
                                return Some(task);
                            }
                        }
                    }
                    None
                });

            match task {
                Some(task) => {
                    if task.state.load() == TaskState::Cancelled {
                        continue;
                    }

                    if task
                        .state
                        .compare_exchange(TaskState::Pending, TaskState::Running)
                        .is_err()
                    {
                        continue;
                    }

                    // Create waker for this task
                    let waker = Self::create_waker(task.clone(), local_queue.clone());
                    let mut cx = Context::from_waker(&waker);

                    // Poll the future
                    let mut future_guard = task.future.lock().unwrap();
                    if let Some(mut future) = future_guard.take() {
                        stats.poll_count.fetch_add(1, Ordering::Relaxed);

                        match future.as_mut().poll(&mut cx) {
                            Poll::Ready(()) => {
                                task.state.store(TaskState::Completed);
                                stats.tasks_completed.fetch_add(1, Ordering::Relaxed);
                                task_registry.write().unwrap().remove(&task.id);
                            }
                            Poll::Pending => {
                                *future_guard = Some(future);
                                task.state.store(TaskState::Waiting);
                            }
                        }
                    }
                }
                None => {
                    // No work available, wait for notification
                    let (lock, cvar) = &*condvar;
                    let mut notified = lock.lock().unwrap();
                    if !*notified && !shutdown.load(Ordering::Relaxed) {
                        let _ = cvar.wait_timeout(notified, Duration::from_millis(10));
                    }
                    *notified = false;
                }
            }
        }
    }

    fn create_waker(task: Arc<Task>, queue: Arc<WorkStealingDeque<Arc<Task>>>) -> Waker {
        let raw = Arc::into_raw(Arc::new((task, queue)));

        let vtable = &RawWakerVTable::new(
            // clone
            |ptr| {
                let arc = unsafe { Arc::from_raw(ptr as *const (Arc<Task>, Arc<WorkStealingDeque<Arc<Task>>>)) };
                let cloned = arc.clone();
                std::mem::forget(arc);
                RawWaker::new(Arc::into_raw(cloned) as *const (), &VTABLE)
            },
            // wake
            |ptr| {
                let arc = unsafe { Arc::from_raw(ptr as *const (Arc<Task>, Arc<WorkStealingDeque<Arc<Task>>>)) };
                let (task, queue) = &*arc;
                if task
                    .state
                    .compare_exchange(TaskState::Waiting, TaskState::Pending)
                    .is_ok()
                {
                    queue.push_back(task.clone());
                }
            },
            // wake_by_ref
            |ptr| {
                let arc = unsafe { Arc::from_raw(ptr as *const (Arc<Task>, Arc<WorkStealingDeque<Arc<Task>>>)) };
                let (task, queue) = &*arc;
                if task
                    .state
                    .compare_exchange(TaskState::Waiting, TaskState::Pending)
                    .is_ok()
                {
                    queue.push_back(task.clone());
                }
                std::mem::forget(arc);
            },
            // drop
            |ptr| {
                unsafe {
                    Arc::from_raw(ptr as *const (Arc<Task>, Arc<WorkStealingDeque<Arc<Task>>>));
                }
            },
        );

        static VTABLE: RawWakerVTable = RawWakerVTable::new(
            |_| RawWaker::new(std::ptr::null(), &VTABLE),
            |_| {},
            |_| {},
            |_| {},
        );

        unsafe { Waker::from_raw(RawWaker::new(raw as *const (), vtable)) }
    }

    /// Shutdown the runtime gracefully
    pub fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);

        // Wake up all workers
        let (lock, cvar) = &*self.condvar;
        {
            let mut notified = lock.lock().unwrap();
            *notified = true;
        }
        cvar.notify_all();

        // Wait for all workers to finish
        for worker in &mut self.workers {
            if let Some(handle) = worker.handle.take() {
                let _ = handle.join();
            }
        }
    }

    /// Get runtime statistics
    pub fn stats(&self) -> RuntimeStats {
        RuntimeStats {
            tasks_spawned: AtomicUsize::new(self.stats.tasks_spawned.load(Ordering::Relaxed)),
            tasks_completed: AtomicUsize::new(self.stats.tasks_completed.load(Ordering::Relaxed)),
            tasks_cancelled: AtomicUsize::new(self.stats.tasks_cancelled.load(Ordering::Relaxed)),
            poll_count: AtomicUsize::new(self.stats.poll_count.load(Ordering::Relaxed)),
            steal_count: AtomicUsize::new(self.stats.steal_count.load(Ordering::Relaxed)),
            timer_fires: AtomicUsize::new(self.stats.timer_fires.load(Ordering::Relaxed)),
        }
    }

    /// Block on a future until completion
    pub fn block_on<F: Future>(&mut self, future: F) -> F::Output {
        let mut future = std::pin::pin!(future);
        let waker = noop_waker();
        let mut cx = Context::from_waker(&waker);

        loop {
            match future.as_mut().poll(&mut cx) {
                Poll::Ready(output) => return output,
                Poll::Pending => {
                    // Process some work while waiting
                    if let Some(task) = self.global_queue.pop_front() {
                        self.workers[0].local_queue.push_back(task);
                    }
                    std::thread::yield_now();
                }
            }
        }
    }
}

fn noop_waker() -> Waker {
    const VTABLE: RawWakerVTable = RawWakerVTable::new(
        |_| RawWaker::new(std::ptr::null(), &VTABLE),
        |_| {},
        |_| {},
        |_| {},
    );
    unsafe { Waker::from_raw(RawWaker::new(std::ptr::null(), &VTABLE)) }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        if !self.shutdown.load(Ordering::Relaxed) {
            self.shutdown();
        }
    }
}

// Mock num_cpus for compilation
mod num_cpus {
    pub fn get() -> usize {
        4
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_task_creation() {
        let task = Task::new(async {}, Priority::Normal);
        assert_eq!(task.state.load(), TaskState::Pending);
    }

    #[test]
    fn test_runtime_spawn() {
        let mut runtime = Runtime::new(RuntimeConfig::default());
        let id = runtime.spawn(async {
            println!("Hello from async task!");
        });
        assert!(runtime.task_registry.read().unwrap().contains_key(&id));
    }

    #[test]
    fn test_timer_wheel() {
        let mut wheel = TimerWheel::new(Duration::from_millis(1), &[256, 64]);
        let task = Task::new(async {}, Priority::Normal);
        wheel.schedule(Instant::now() + Duration::from_millis(10), task);
    }
}
