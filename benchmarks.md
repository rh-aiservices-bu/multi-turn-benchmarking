python guidellm/multi-turn-benchmark.py $LLM_URL \                                         
  --conversations 20 \
  --turns 10 \
  --max-tokens 150 \
  --verbose

## llm-d

Total time: 242.75s
Total requests: 110
Completed conversations: 11/11
Requests per second: 0.45

Time to First Token (TTFT):
  Min:         51.19 ms
  Max:        804.54 ms
  Mean:       120.98 ms
  P50:         92.09 ms
  P95:        271.60 ms
  P99:        674.21 ms

Total Request Time:
  Min:       3984.05 ms
  Max:      12000.39 ms
  Mean:      7424.42 ms
  P50:       6940.05 ms
  P95:      11356.77 ms

TTFT by Turn Number:
  Turn  1:     361.79 ms avg (11 requests)
  Turn  2:      83.43 ms avg (11 requests)
  Turn  3:      86.10 ms avg (11 requests)
  Turn  4:      89.03 ms avg (11 requests)
  Turn  5:      89.17 ms avg (11 requests)
  Turn  6:      93.51 ms avg (11 requests)
  Turn  7:     103.59 ms avg (11 requests)
  Turn  8:      90.64 ms avg (11 requests)
  Turn  9:      97.17 ms avg (11 requests)
  Turn 10:     115.32 ms avg (11 requests)

TTFT by Document Type:
  CODE:       122.19 ms avg (50 requests)
  TEXT:       119.97 ms avg (60 requests)

First Turn vs Subsequent Turns (Prefix Caching Indicator):
  First turn avg:      361.79 ms
  Later turns avg:      94.22 ms
  Speedup ratio:         3.84x


## vllm

Total time: 227.58s
Total requests: 110
Completed conversations: 11/11
Requests per second: 0.48

Time to First Token (TTFT):
  Min:         50.13 ms
  Max:        850.20 ms
  Mean:       211.82 ms
  P50:        123.22 ms
  P95:        744.71 ms
  P99:        840.95 ms

Total Request Time:
  Min:       3650.51 ms
  Max:      11100.05 ms
  Mean:      6990.35 ms
  P50:       6906.98 ms
  P95:       9537.97 ms

TTFT by Turn Number:
  Turn  1:     351.64 ms avg (11 requests)
  Turn  2:     295.65 ms avg (11 requests)
  Turn  3:     284.53 ms avg (11 requests)
  Turn  4:     238.34 ms avg (11 requests)
  Turn  5:     185.91 ms avg (11 requests)
  Turn  6:     123.13 ms avg (11 requests)
  Turn  7:     191.55 ms avg (11 requests)
  Turn  8:     122.72 ms avg (11 requests)
  Turn  9:     124.31 ms avg (11 requests)
  Turn 10:     200.44 ms avg (11 requests)

TTFT by Document Type:
  CODE:       244.53 ms avg (50 requests)
  TEXT:       184.57 ms avg (60 requests)

First Turn vs Subsequent Turns (Prefix Caching Indicator):
  First turn avg:      351.64 ms
  Later turns avg:     196.29 ms
  Speedup ratio:         1.79x


# First, create a ConfigMap from your local script
oc create configmap benchmark-script -n demo-llm \
  --from-file=multi-turn-benchmark.py=/Users/phayes/projects/rhoai3-llmd/guidellm/multi-turn-benchmark.py

  oc create configmap seed-documents --from-file=guidellm/seed-documents/

oc run benchmark-runner -n demo-llm -it --rm \
  --image=python:3.11-slim \
  --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "benchmark-runner",
      "image": "python:3.11-slim",
      "command": ["bash"],
      "stdin": true,
      "tty": true,
      "env": [
        {"name": "HOME", "value": "/tmp"},
        {"name": "PIP_CACHE_DIR", "value": "/tmp/pip-cache"}
      ],
      "volumeMounts": [
        {
          "name": "script",
          "mountPath": "/app"
        },
        {
          "name": "seed-documents",
          "mountPath": "/app/seed-documents"
        }
      ]
    }],
    "volumes": [
      {
        "name": "script",
        "configMap": {
          "name": "benchmark-script"
        }
      },
      {
        "name": "seed-documents",
        "configMap": {
          "name": "seed-documents"
        }
      }
    ]
  }
}'

Once inside the pod, install dependencies and run the benchmark:
# Install httpx
pip install httpx



# Run against the internal service

vllm:


python /app/multi-turn-benchmark.py http://qwen-vllm-lb.demo-llm.svc.cluster.local:8000/v1 -d /app/seed-documents

llm-d
python /app/multi-turn-benchmark.py http://openshift-ai-inference-openshift-default.openshift-ingress.svc.cluster.local/demo-llm/qwen/v1 -d /app/seed-documents

Alternative: Create a persistent pod with the script mounted
# First, create a ConfigMap from your local script
oc create configmap benchmark-script -n demo-llm \
  --from-file=multi-turn-benchmark.py=/Users/phayes/projects/rhoai3-llmd/guidellm/multi-turn-benchmark.py

# Then create a pod that mounts it
oc run benchmark-runner -n demo-llm -it --rm \
  --image=python:3.11-slim \
  --restart=Never \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "benchmark-runner",
      "image": "python:3.11-slim",
      "command": ["bash"],
      "stdin": true,
      "tty": true,
      "volumeMounts": [{
        "name": "script",
        "mountPath": "/app"
      }]
    }],
    "volumes": [{
      "name": "script",
      "configMap": {
        "name": "benchmark-script"
      }
    }]
  }
}'
Then inside the pod:
pip install httpx
python /app/multi-turn-benchmark.py http://qwen-vllm-predictor.demo-llm.svc.cluster.local:80/v1
For llm-d, use:
python /app/multi-turn-benchmark.py https://qwen-gateway.demo-llm.svc.cluster.local:443/v1



Results:

vllm:
Time to First Token (TTFT):
  Min:         50.13 ms
  Max:        850.20 ms
  Mean:       211.82 ms
  P50:        123.22 ms
  P95:        744.71 ms
  P99:        840.95 ms

llm-d: 
Time to First Token (TTFT):
  Min:         51.19 ms
  Max:        804.54 ms
  Mean:       120.98 ms
  P50:         92.09 ms
  P95:        271.60 ms
  P99:        674.21 ms
