#!/usr/bin/env python3
"""
Multi-turn conversation benchmark tool for LLM inference testing.

This tool simulates multiple interleaved conversations using real-world seed documents
to test prefix caching and KV cache efficiency in LLM deployments.

Documents are categorized as either source code or text, and appropriate instructions
are used for each type to simulate realistic LLM use cases.
"""

import argparse
import asyncio
import time
import random
import os
from dataclasses import dataclass, field
from typing import Optional
from pathlib import Path
import httpx


# Document type classification based on file extension
CODE_EXTENSIONS = {'.py', '.go', '.rs', '.tsx', '.ts', '.js', '.sql', '.java', '.c', '.cpp', '.rb'}
TEXT_EXTENSIONS = {'.md', '.txt', '.rst', '.html'}


@dataclass
class SeedDocument:
    """Represents a seed document for conversation starters."""
    path: Path
    content: str
    is_code: bool
    name: str

    @classmethod
    def load(cls, path: Path) -> 'SeedDocument':
        """Load a seed document from disk."""
        content = path.read_text(encoding='utf-8')
        ext = path.suffix.lower()
        is_code = ext in CODE_EXTENSIONS
        return cls(path=path, content=content, is_code=is_code, name=path.name)


@dataclass
class ConversationStats:
    """Statistics for a single request."""
    turn: int
    ttft_ms: Optional[float] = None  # Time to first token
    total_time_ms: Optional[float] = None
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    total_tokens: Optional[int] = None


@dataclass
class Conversation:
    """Represents a multi-turn conversation."""
    id: int
    document: SeedDocument
    messages: list = field(default_factory=list)
    current_turn: int = 0
    stats: list = field(default_factory=list)
    completed: bool = False

    # Initial instructions for CODE documents
    CODE_STARTERS = [
        "Review this code and identify any bugs or issues that need to be fixed:",
        "Add detailed comments to explain what each function does in this code:",
        "Refactor this code to improve readability and maintainability:",
        "Identify potential security vulnerabilities in this code:",
        "Suggest performance optimizations for this code:",
        "Write unit tests for the main functions in this code:",
        "Explain the overall architecture and design patterns used in this code:",
        "Find any code smells or anti-patterns in this code:",
    ]

    # Initial instructions for TEXT documents
    TEXT_STARTERS = [
        "Summarize the main points of this document:",
        "Create a bulleted list of the key takeaways from this document:",
        "Explain the most important concepts discussed in this document:",
        "What are the main arguments or findings presented in this document?",
        "Create an executive summary of this document:",
        "Identify the key themes and topics covered in this document:",
        "What conclusions can be drawn from this document?",
        "Extract the most important facts and figures from this document:",
    ]

    # Follow-up prompts for CODE conversations
    CODE_CONTINUATIONS = [
        "The code still has issues. Can you look more carefully?",
        "Can you explain that fix in more detail?",
        "Are there any other bugs you might have missed?",
        "How would you improve the error handling?",
        "What about edge cases - are those handled properly?",
        "Can you show me what the fixed code would look like?",
        "Is there a more efficient way to implement this?",
        "What tests would you write to verify these fixes?",
        "Are there any security concerns I should be aware of?",
        "How would you refactor this to be more maintainable?",
    ]

    # Follow-up prompts for TEXT conversations
    TEXT_CONTINUATIONS = [
        "Can you make that summary longer and more detailed?",
        "That's too long. Can you make it more concise?",
        "Can you focus more on the technical aspects?",
        "What are the practical implications of these findings?",
        "Can you explain that in simpler terms?",
        "Are there any counterarguments to consider?",
        "How does this compare to other work in the field?",
        "What are the limitations mentioned in the document?",
        "Can you highlight the most surprising or novel findings?",
        "What questions does this document leave unanswered?",
    ]

    def get_starter_prompt(self) -> str:
        """Get an initial prompt with the document content."""
        if self.document.is_code:
            instruction = self.CODE_STARTERS[self.id % len(self.CODE_STARTERS)]
        else:
            instruction = self.TEXT_STARTERS[self.id % len(self.TEXT_STARTERS)]

        return f"{instruction}\n\n```\n{self.document.content}\n```"

    def get_continuation_prompt(self) -> str:
        """Get a random continuation prompt based on document type."""
        if self.document.is_code:
            return random.choice(self.CODE_CONTINUATIONS)
        else:
            return random.choice(self.TEXT_CONTINUATIONS)

    def add_user_message(self, content: str):
        """Add a user message to the conversation."""
        self.messages.append({"role": "user", "content": content})

    def add_assistant_message(self, content: str):
        """Add an assistant message to the conversation."""
        self.messages.append({"role": "assistant", "content": content})


class MultiturnBenchmark:
    """Manages multiple interleaved conversations with parallel execution."""

    def __init__(
        self,
        base_url: str,
        seed_documents_dir: str,
        num_conversations: int = 11,
        turns_per_conversation: int = 10,
        max_tokens: int = 500,
        timeout: float = 120.0,
        verbose: bool = False,
        parallel: int = 4,
        min_delay: float = 0.5,
        max_delay: float = 2.0,
    ):
        self.base_url = base_url.rstrip("/")
        self.seed_documents_dir = Path(seed_documents_dir)
        self.num_conversations = num_conversations
        self.turns_per_conversation = turns_per_conversation
        self.max_tokens = max_tokens
        self.timeout = timeout
        self.verbose = verbose
        self.parallel = parallel
        self.min_delay = min_delay
        self.max_delay = max_delay
        self.model_name: Optional[str] = None
        self.conversations: list[Conversation] = []
        self.client: Optional[httpx.AsyncClient] = None
        self.seed_documents: list[SeedDocument] = []

    def load_seed_documents(self):
        """Load all seed documents from the directory."""
        if not self.seed_documents_dir.exists():
            raise ValueError(f"Seed documents directory not found: {self.seed_documents_dir}")

        files = sorted(self.seed_documents_dir.iterdir())
        for file_path in files:
            if file_path.is_file() and file_path.suffix.lower() in (CODE_EXTENSIONS | TEXT_EXTENSIONS):
                try:
                    doc = SeedDocument.load(file_path)
                    self.seed_documents.append(doc)
                    doc_type = "CODE" if doc.is_code else "TEXT"
                    print(f"  Loaded: {doc.name} ({doc_type}, {len(doc.content):,} chars)")
                except Exception as e:
                    print(f"  Warning: Failed to load {file_path.name}: {e}")

        if not self.seed_documents:
            raise ValueError(f"No valid seed documents found in {self.seed_documents_dir}")

        print(f"\nLoaded {len(self.seed_documents)} seed documents")
        code_count = sum(1 for d in self.seed_documents if d.is_code)
        text_count = len(self.seed_documents) - code_count
        print(f"  Code documents: {code_count}")
        print(f"  Text documents: {text_count}")

    async def get_model_name(self) -> str:
        """Fetch available models and return the first one."""
        async with httpx.AsyncClient(verify=False, timeout=self.timeout) as client:
            response = await client.get(f"{self.base_url}/models")
            response.raise_for_status()
            data = response.json()

            if "data" in data and len(data["data"]) > 0:
                model_name = data["data"][0]["id"]
                print(f"✓ Found model: {model_name}")
                return model_name
            else:
                raise ValueError("No models available at the endpoint")

    async def send_chat_request(
        self,
        conversation: Conversation
    ) -> tuple[str, ConversationStats]:
        """Send a chat completion request and collect stats."""
        start_time = time.perf_counter()
        first_token_time: Optional[float] = None
        full_response = ""

        payload = {
            "model": self.model_name,
            "messages": conversation.messages,
            "max_tokens": self.max_tokens,
            "stream": True,
        }

        stats = ConversationStats(turn=conversation.current_turn)

        try:
            async with self.client.stream(
                "POST",
                f"{self.base_url}/chat/completions",
                json=payload,
                timeout=self.timeout,
            ) as response:
                response.raise_for_status()

                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        data_str = line[6:]
                        if data_str.strip() == "[DONE]":
                            break

                        try:
                            import json
                            data = json.loads(data_str)

                            # Extract content
                            if "choices" in data and len(data["choices"]) > 0:
                                delta = data["choices"][0].get("delta", {})
                                content = delta.get("content", "")

                                # Record TTFT only when first actual content token arrives
                                if content and first_token_time is None:
                                    first_token_time = time.perf_counter()
                                    stats.ttft_ms = (first_token_time - start_time) * 1000

                                full_response += content

                            # Extract usage if available
                            if "usage" in data and data["usage"]:
                                stats.prompt_tokens = data["usage"].get("prompt_tokens")
                                stats.completion_tokens = data["usage"].get("completion_tokens")
                                stats.total_tokens = data["usage"].get("total_tokens")

                        except json.JSONDecodeError:
                            continue

            end_time = time.perf_counter()
            stats.total_time_ms = (end_time - start_time) * 1000

        except Exception as e:
            print(f"  ✗ Error in conversation {conversation.id}: {e}")
            stats.total_time_ms = (time.perf_counter() - start_time) * 1000

        return full_response, stats

    async def run_conversation_turn(self, conversation: Conversation) -> bool:
        """Run a single turn of a conversation. Returns True if conversation should continue."""
        if conversation.completed:
            return False

        # Determine the prompt for this turn
        if conversation.current_turn == 0:
            prompt = conversation.get_starter_prompt()
            action = "Starting"
            prompt_preview = f"{conversation.document.name}"
        else:
            prompt = conversation.get_continuation_prompt()
            action = "Continuing"
            prompt_preview = prompt[:50]

        conversation.add_user_message(prompt)

        # Send request and get response
        response_text, stats = await self.send_chat_request(conversation)
        conversation.stats.append(stats)

        if response_text:
            conversation.add_assistant_message(response_text)

        # Log status
        ttft_str = f"{stats.ttft_ms:.1f}ms" if stats.ttft_ms else "N/A"
        total_str = f"{stats.total_time_ms:.1f}ms" if stats.total_time_ms else "N/A"
        tokens_str = f"{stats.total_tokens}" if stats.total_tokens else "N/A"
        doc_type = "CODE" if conversation.document.is_code else "TEXT"

        print(
            f"  [{action:10}] Conv {conversation.id:2d} ({doc_type}) | "
            f"Turn {conversation.current_turn + 1:2d}/{self.turns_per_conversation} | "
            f"TTFT: {ttft_str:>8} | "
            f"Total: {total_str:>10} | "
            f"Tokens: {tokens_str:>6} | "
            f"{prompt_preview}"
        )

        if self.verbose and response_text:
            print(f"      Response: \"{response_text[:100]}...\"")

        conversation.current_turn += 1

        if conversation.current_turn >= self.turns_per_conversation:
            conversation.completed = True
            return False

        return True

    # Warm-up prompts (different from benchmark prompts)
    WARMUP_PROMPTS = [
        "What is the capital of France?",
        "How many planets are in the solar system?",
        "What color is the sky?",
        "Who wrote Romeo and Juliet?",
        "What is 2 + 2?",
        "Name a popular programming language",
        "What is the largest ocean?",
        "How many days are in a week?",
        "What is the speed of light?",
        "Name a famous scientist",
        "What is photosynthesis?",
        "How many continents are there?",
        "What is the capital of Japan?",
        "Name a famous painter",
        "What is gravity?",
        "How many hours in a day?",
        "What is the largest mammal?",
        "Name a famous composer",
        "What causes rain?",
        "What is the smallest planet?",
    ]

    async def run_warmup(self, num_requests: int = 20):
        """Run warm-up requests to populate caches across all replicas."""
        print(f"\n{'='*80}")
        print("WARM-UP PHASE")
        print(f"{'='*80}")
        print(f"Sending {num_requests} warm-up requests to populate caches...")

        warmup_stats = []
        for i in range(num_requests):
            prompt = self.WARMUP_PROMPTS[i % len(self.WARMUP_PROMPTS)]
            payload = {
                "model": self.model_name,
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 50,  # Short responses for warm-up
                "stream": True,
            }

            start_time = time.perf_counter()
            first_token_time = None

            try:
                async with self.client.stream(
                    "POST",
                    f"{self.base_url}/chat/completions",
                    json=payload,
                    timeout=self.timeout,
                ) as response:
                    response.raise_for_status()
                    async for line in response.aiter_lines():
                        if line.startswith("data: "):
                            data_str = line[6:]
                            if data_str.strip() == "[DONE]":
                                break
                            try:
                                import json
                                data = json.loads(data_str)
                                if "choices" in data and len(data["choices"]) > 0:
                                    delta = data["choices"][0].get("delta", {})
                                    content = delta.get("content", "")
                                    if content and first_token_time is None:
                                        first_token_time = time.perf_counter()
                            except json.JSONDecodeError:
                                continue

                end_time = time.perf_counter()
                ttft_ms = (first_token_time - start_time) * 1000 if first_token_time else None
                total_ms = (end_time - start_time) * 1000
                warmup_stats.append((ttft_ms, total_ms))

                ttft_str = f"{ttft_ms:.1f}ms" if ttft_ms else "N/A"
                print(f"  Warm-up {i+1:2d}/{num_requests}: TTFT={ttft_str:>8} | Total={total_ms:.1f}ms | \"{prompt[:40]}...\"")

            except Exception as e:
                print(f"  Warm-up {i+1:2d}/{num_requests}: Error - {e}")

        # Summary
        valid_ttfts = [t[0] for t in warmup_stats if t[0] is not None]
        if valid_ttfts:
            avg_ttft = sum(valid_ttfts) / len(valid_ttfts)
            print(f"\nWarm-up complete. Avg TTFT: {avg_ttft:.1f}ms")
        print(f"{'='*80}\n")

    async def run_parallel_conversations(self):
        """Run conversations in parallel with random delays to simulate multiple users."""
        print(f"\nStarting parallel execution with {self.parallel} concurrent workers...")
        print(f"Random delays between requests: {self.min_delay}s - {self.max_delay}s\n")

        # Create a queue of (conversation_id, turn_number) tasks
        task_queue: asyncio.Queue = asyncio.Queue()

        # Initialize: add first turn for all conversations
        for conv in self.conversations:
            await task_queue.put(conv.id)

        # Track active tasks per conversation to prevent parallel execution of same conversation
        conversation_locks = {conv.id: asyncio.Lock() for conv in self.conversations}

        async def worker(worker_id: int):
            """Worker that processes conversation turns from the queue."""
            while True:
                try:
                    # Get next conversation from queue with timeout
                    try:
                        conv_id = await asyncio.wait_for(task_queue.get(), timeout=1.0)
                    except asyncio.TimeoutError:
                        # Check if all conversations are complete
                        if all(c.completed for c in self.conversations):
                            break
                        continue

                    conv = self.conversations[conv_id]

                    # Skip if already completed
                    if conv.completed:
                        task_queue.task_done()
                        continue

                    # Acquire lock for this conversation to prevent parallel turns
                    async with conversation_locks[conv_id]:
                        # Add random delay to simulate real user behavior
                        delay = random.uniform(self.min_delay, self.max_delay)
                        await asyncio.sleep(delay)

                        # Run the turn
                        should_continue = await self.run_conversation_turn(conv)

                        # If conversation should continue, add next turn to queue
                        if should_continue:
                            await task_queue.put(conv_id)

                    task_queue.task_done()

                except Exception as e:
                    print(f"  Worker {worker_id} error: {e}")

        # Create worker tasks
        workers = [asyncio.create_task(worker(i)) for i in range(self.parallel)]

        # Wait for all tasks to complete
        await task_queue.join()

        # Cancel workers
        for w in workers:
            w.cancel()

        # Wait for workers to finish
        await asyncio.gather(*workers, return_exceptions=True)

    async def run(self):
        """Run the interleaved multi-turn benchmark."""
        print("=" * 80)
        print("Multi-Turn Conversation Benchmark (Seed Documents)")
        print("=" * 80)
        print(f"Target URL: {self.base_url}")
        print(f"Seed documents directory: {self.seed_documents_dir}")
        print(f"Conversations: {self.num_conversations}")
        print(f"Turns per conversation: {self.turns_per_conversation}")
        print(f"Max tokens per response: {self.max_tokens}")
        print(f"Parallel workers: {self.parallel}")
        print(f"Request delay range: {self.min_delay}s - {self.max_delay}s")
        print("=" * 80)

        # Load seed documents
        print("\nLoading seed documents...")
        self.load_seed_documents()

        # Get model name
        self.model_name = await self.get_model_name()

        # Initialize conversations (one per document, cycling if needed)
        self.conversations = []
        for i in range(self.num_conversations):
            doc = self.seed_documents[i % len(self.seed_documents)]
            self.conversations.append(Conversation(id=i, document=doc))

        print(f"\nInitialized {len(self.conversations)} conversations")

        # Create HTTP client with connection pooling disabled for proper load balancing
        # This ensures each request can be routed to a different backend pod
        limits = httpx.Limits(max_keepalive_connections=0, max_connections=100)
        self.client = httpx.AsyncClient(verify=False, timeout=self.timeout, limits=limits)

        try:
            # Run warm-up phase first
            await self.run_warmup(num_requests=20)

            print("Starting interleaved conversations...\n")
            start_time = time.perf_counter()

            # Run conversations in parallel
            await self.run_parallel_conversations()

            end_time = time.perf_counter()
            total_time = end_time - start_time

            # Print summary
            self._print_summary(total_time)

        finally:
            await self.client.aclose()

    def _print_summary(self, total_time: float):
        """Print benchmark summary statistics."""
        print("\n" + "=" * 80)
        print("BENCHMARK SUMMARY")
        print("=" * 80)

        all_stats: list[ConversationStats] = []
        for conv in self.conversations:
            all_stats.extend(conv.stats)

        if not all_stats:
            print("No stats collected")
            return

        # Calculate TTFT statistics
        ttft_values = [s.ttft_ms for s in all_stats if s.ttft_ms is not None]
        total_times = [s.total_time_ms for s in all_stats if s.total_time_ms is not None]

        total_requests = len(all_stats)
        completed_conversations = sum(1 for c in self.conversations if c.completed)

        print(f"\nTotal time: {total_time:.2f}s")
        print(f"Total requests: {total_requests}")
        print(f"Completed conversations: {completed_conversations}/{self.num_conversations}")
        print(f"Requests per second: {total_requests / total_time:.2f}")

        if ttft_values:
            print(f"\nTime to First Token (TTFT):")
            print(f"  Min:    {min(ttft_values):>10.2f} ms")
            print(f"  Max:    {max(ttft_values):>10.2f} ms")
            print(f"  Mean:   {sum(ttft_values) / len(ttft_values):>10.2f} ms")
            sorted_ttft = sorted(ttft_values)
            p50_idx = int(len(sorted_ttft) * 0.50)
            p95_idx = int(len(sorted_ttft) * 0.95)
            p99_idx = int(len(sorted_ttft) * 0.99)
            print(f"  P50:    {sorted_ttft[p50_idx]:>10.2f} ms")
            print(f"  P95:    {sorted_ttft[min(p95_idx, len(sorted_ttft)-1)]:>10.2f} ms")
            print(f"  P99:    {sorted_ttft[min(p99_idx, len(sorted_ttft)-1)]:>10.2f} ms")

        if total_times:
            print(f"\nTotal Request Time:")
            print(f"  Min:    {min(total_times):>10.2f} ms")
            print(f"  Max:    {max(total_times):>10.2f} ms")
            print(f"  Mean:   {sum(total_times) / len(total_times):>10.2f} ms")
            sorted_total = sorted(total_times)
            p50_idx = int(len(sorted_total) * 0.50)
            p95_idx = int(len(sorted_total) * 0.95)
            print(f"  P50:    {sorted_total[p50_idx]:>10.2f} ms")
            print(f"  P95:    {sorted_total[min(p95_idx, len(sorted_total)-1)]:>10.2f} ms")

        # Per-turn analysis
        print(f"\nTTFT by Turn Number:")
        for turn in range(self.turns_per_conversation):
            turn_ttfts = [
                s.ttft_ms for s in all_stats
                if s.turn == turn and s.ttft_ms is not None
            ]
            if turn_ttfts:
                avg_ttft = sum(turn_ttfts) / len(turn_ttfts)
                print(f"  Turn {turn + 1:2d}: {avg_ttft:>10.2f} ms avg ({len(turn_ttfts)} requests)")

        # Analysis by document type
        print(f"\nTTFT by Document Type:")
        code_ttfts = []
        text_ttfts = []
        for conv in self.conversations:
            for stat in conv.stats:
                if stat.ttft_ms is not None:
                    if conv.document.is_code:
                        code_ttfts.append(stat.ttft_ms)
                    else:
                        text_ttfts.append(stat.ttft_ms)

        if code_ttfts:
            print(f"  CODE:   {sum(code_ttfts)/len(code_ttfts):>10.2f} ms avg ({len(code_ttfts)} requests)")
        if text_ttfts:
            print(f"  TEXT:   {sum(text_ttfts)/len(text_ttfts):>10.2f} ms avg ({len(text_ttfts)} requests)")

        # First turn vs subsequent turns (prefix caching indicator)
        print(f"\nFirst Turn vs Subsequent Turns (Prefix Caching Indicator):")
        first_turn_ttfts = [s.ttft_ms for s in all_stats if s.turn == 0 and s.ttft_ms is not None]
        later_turn_ttfts = [s.ttft_ms for s in all_stats if s.turn > 0 and s.ttft_ms is not None]

        if first_turn_ttfts:
            print(f"  First turn avg:  {sum(first_turn_ttfts)/len(first_turn_ttfts):>10.2f} ms")
        if later_turn_ttfts:
            print(f"  Later turns avg: {sum(later_turn_ttfts)/len(later_turn_ttfts):>10.2f} ms")
        if first_turn_ttfts and later_turn_ttfts:
            speedup = (sum(first_turn_ttfts)/len(first_turn_ttfts)) / (sum(later_turn_ttfts)/len(later_turn_ttfts))
            print(f"  Speedup ratio:   {speedup:>10.2f}x")

        print("\n" + "=" * 80)


def main():
    parser = argparse.ArgumentParser(
        description="Multi-turn conversation benchmark using seed documents for realistic LLM testing",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s http://localhost:8000/v1
  %(prog)s https://my-llm-service.example.com/v1 --conversations 20 --turns 5
  %(prog)s $LLM_URL --parallel 8 --min-delay 0.1 --max-delay 1.0
  %(prog)s $LLM_URL --seed-documents ./my-documents
        """
    )

    parser.add_argument(
        "url",
        help="Base URL of the LLM API (e.g., http://localhost:8000/v1)"
    )
    parser.add_argument(
        "-d", "--seed-documents",
        type=str,
        default=os.path.join(os.path.dirname(__file__), "seed-documents"),
        help="Directory containing seed documents (default: ./seed-documents)"
    )
    parser.add_argument(
        "-c", "--conversations",
        type=int,
        default=11,
        help="Number of concurrent conversations (default: 11, one per document)"
    )
    parser.add_argument(
        "-t", "--turns",
        type=int,
        default=10,
        help="Number of turns per conversation (default: 10)"
    )
    parser.add_argument(
        "-m", "--max-tokens",
        type=int,
        default=500,
        help="Maximum tokens per response (default: 500)"
    )
    parser.add_argument(
        "-p", "--parallel",
        type=int,
        default=4,
        help="Number of parallel workers (default: 4)"
    )
    parser.add_argument(
        "--min-delay",
        type=float,
        default=0.5,
        help="Minimum delay between requests in seconds (default: 0.5)"
    )
    parser.add_argument(
        "--max-delay",
        type=float,
        default=2.0,
        help="Maximum delay between requests in seconds (default: 2.0)"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=120.0,
        help="Request timeout in seconds (default: 120)"
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Show response previews"
    )

    args = parser.parse_args()

    benchmark = MultiturnBenchmark(
        base_url=args.url,
        seed_documents_dir=args.seed_documents,
        num_conversations=args.conversations,
        turns_per_conversation=args.turns,
        max_tokens=args.max_tokens,
        timeout=args.timeout,
        verbose=args.verbose,
        parallel=args.parallel,
        min_delay=args.min_delay,
        max_delay=args.max_delay,
    )

    asyncio.run(benchmark.run())


if __name__ == "__main__":
    main()
