# Phi-2 vLLM Benchmark Report

## Executive Summary

I evaluated Phi-2 served through vLLM on a single NVIDIA Tesla T4 GPU using KServe on EKS. I tested several vLLM scheduler configurations by varying `max_num_seqs`, `max_num_batched_tokens`, and request concurrency. The main finding was that those scheduler settings had limited effect on this short-prompt workload; the service behaved similarly across profiles and reached an effective saturation point around 10 concurrent requests. Across the tested runs, I observed approximately 240–248 tokens/sec, about 4 requests/sec, 100% success rate, and 0 errors.

## Benchmark Methodology

I used the benchmark automation in [load-testing/scripts/run-benchmark.sh](../../load-testing/scripts/run-benchmark.sh) to drive the full workflow. The runner loads profile definitions from [load-testing/scripts/configs](../../load-testing/scripts/configs), patches the KServe InferenceService arguments for each profile, runs the load generator from [load-testing/scripts/python/loadgen.py](../../load-testing/scripts/python/loadgen.py), summarizes request-level results with [load-testing/scripts/python/statistic.py](../../load-testing/scripts/python/statistic.py), and collects Prometheus metrics with [load-testing/scripts/python/metrics.py](../../load-testing/scripts/python/metrics.py).

For each concurrency level, I ran:

- Warmup: 120 seconds
- Measurement: 480 seconds

Concurrency levels:

- 1
- 5
- 10
- 20
- 40

Workload:

Prompt:

> You are a concise assistant. Summarize Kubernetes autoscaling in one short paragraph.

Generation settings:

- `max_tokens=128`
- `temperature=0.2`

### Benchmark artifacts

The benchmark runner writes results into [load-testing/results](../../load-testing/results). When the benchmark is run, it produces:

- [load-testing/results/benchmark-summary.csv](../../load-testing/results/benchmark-summary.csv)
- [load-testing/results/latency-vs-concurrency.csv](../../load-testing/results/latency-vs-concurrency.csv)
- [load-testing/results/throughput-vs-concurrency.csv](../../load-testing/results/throughput-vs-concurrency.csv)
- [load-testing/results/request-level](../../load-testing/results/request-level)
- [load-testing/results/benchmark.log](../../load-testing/results/benchmark.log)

---

# Environment

## Infrastructure

- Amazon EKS
- KServe InferenceService
- vLLM
- Prometheus
- Grafana

## Hardware

- NVIDIA Tesla T4 (g4dn)

## Model

- Phi-2 (`microsoft/phi-2`)

## Runtime Configuration

- `--gpu-memory-utilization=0.85`

---

## Test Duration

Per concurrency level:

- Warmup: 120 seconds
- Measurement: 480 seconds

## Concurrency Levels

- 1
- 5
- 10
- 20
- 40

## Workload

Prompt:

> You are a concise assistant. Summarize Kubernetes autoscaling in one short paragraph.

Generation settings:

- `max_tokens=128`
- `temperature=0.2`

---

# Tested Configurations

| Test ID | max_num_seqs | max_num_batched_tokens |
|----------|----------:|----------:|
| A | 8 | 2048 |
| B | 16 | 2048 |
| C | 32 | 2048 |
| D | 16 | 512 |
| E | 16 | 1024 |
| F | 16 | 2048 (repeat) |

---

# Workload Characteristics

The benchmark workload was intentionally small:

- Short prompt
- 128 token output limit
- Small context size
- Low memory footprint

Observed KV-cache utilization remained approximately:

```text
1% - 2%
```

throughout all tests.

This means the workload never created significant memory pressure and likely did not exercise the limits that `max_num_seqs` and `max_num_batched_tokens` are designed to control.

As a result, many configuration changes produced almost identical performance results.

---

# Throughput Results

## Peak Token Throughput

| Test | Peak Tokens/sec |
|--------|--------:|
| A | 246.8 |
| B | 247.2 |
| C | 246.1 |
| D | 247.8 |
| E | 239.3 |
| F | 239.8 |

### Best Result

```text
247.8 tokens/sec
```

---

## Request Throughput (RPS)

| Concurrency | Typical RPS |
|------------:|------------:|
| 1 | ~0.66 |
| 5 | ~2.6 |
| 10 | ~4.0 |
| 20 | ~4.0 |
| 40 | ~4.0 |

### Observation

Request throughput increases up to approximately:

```text
10 concurrent requests
```

After that point:

```text
RPS stops increasing
```

even as additional concurrency is added.

---

# Latency Results

## Average Latency

| Concurrency | Average Latency |
|------------:|----------------:|
| 1 | ~1.5 s |
| 5 | ~1.9 s |
| 10 | ~2.5 s |
| 20 | ~5.0 s |
| 40 | ~9.9 s |

---

## P95 Latency

| Concurrency | P95 |
|------------:|-----:|
| 1 | ~2.1 s |
| 5 | ~2.7 s |
| 10 | ~3.4 s |
| 20 | ~6.0 s |
| 40 | ~11.0 s |

---

## TTFT Observations

Observed Grafana metrics:

```text
TTFT p95 ≈ 3.8s
```

under moderate load and:

```text
TTFT p95 ≈ 9.6s
```

under heavy load.

This increase correlated with scheduler queue growth rather than increased prefill time.

---

# Scheduler Behavior

As concurrency increased:

```text
1 → 5 → 10
```

throughput increased.

Beyond approximately:

```text
10 concurrent requests
```

additional load primarily resulted in:

- larger queues
- higher TTFT
- higher end-to-end latency

rather than higher throughput.

Example:

| Concurrency | Waiting Requests |
|------------:|----------------:|
| 10 | ~2 |
| 20 | ~12 |
| 40 | ~32 |

This indicates the service reached an effective operating limit and additional requests spent more time waiting before execution.

---

# Prefill vs Decode Analysis

Observed Grafana metrics:

```text
Prefill p95 ≈ 285 ms
Decode p95 ≈ 3 s
```

### Interpretation

Prompt processing was relatively inexpensive.

Most inference time was spent generating output tokens.

This benchmark reinforces the importance of analyzing:

- Prefill latency
- Decode latency

separately.

Combining them into a single latency number hides where time is actually being spent.

---

# Memory Observations

## KV Cache

Observed:

```text
~1% - 2%
```

utilization.

## Preemptions

Observed:

```text
0
```

throughout all benchmark runs.

### Conclusion

No evidence of:

- KV-cache exhaustion
- memory pressure
- scheduler preemption

was observed.

---

# Impact of max_num_seqs

Tested values:

```text
8
16
32
```

### Expected

Higher values may:

- increase active sequence capacity
- improve throughput
- improve batching efficiency

### Observed

Throughput:

```text
~240 TPS
```

Latency:

```text
Nearly identical
```

RPS:

```text
Nearly identical
```

### Conclusion

For this workload:

```text
max_num_seqs was not the dominant bottleneck.
```

---

# Impact of max_num_batched_tokens

Tested values:

```text
512
1024
2048
```

### Expected

Larger token budgets may allow:

- larger batches
- higher utilization
- improved throughput

### Observed

Minimal differences across all measured metrics.

### Conclusion

The workload was too small to significantly stress the batched-token budget.

---

# Benchmark Limitations

This benchmark characterizes:

- Short prompts
- Small contexts
- 128-token generations
- Interactive inference workloads

It does **not** characterize:

- Long-context prompts
- RAG workloads
- Multi-thousand-token generations
- Heavy KV-cache pressure
- Memory-constrained workloads

Future testing with:

- larger prompts
- 512-2048 token outputs
- mixed prompt sizes

would likely expose stronger differences between vLLM scheduler configurations.

---

# Lessons Learned

## 1. Throughput and Latency Are Tradeoffs

Increasing concurrency improved throughput until saturation.

After saturation:

```text
Latency increased
Queue depth increased
TTFT increased
```

while throughput remained nearly constant.

---

## 2. TTFT Is Not Pure Compute Time

TTFT includes:

- scheduler delay
- queueing
- prefill
- first decode step

Large TTFT values do not automatically imply slow model execution.

---

## 3. Separate Prefill and Decode

Observed:

```text
Prefill ≈ 285ms
Decode ≈ 3s
```

Most time was spent decoding rather than processing prompts.

---

## 4. Benchmarks Often Reveal Different Bottlenecks Than Expected

The original goal was to evaluate:

```text
max_num_seqs
max_num_batched_tokens
```

The key finding was instead:

```text
Those settings had little impact
for the chosen workload.
```

---

## 5. Metrics Require Validation

An important lesson from this exercise was understanding how metrics are collected and aggregated.

Future benchmark iterations should verify all Prometheus queries and aggregation methods before drawing detailed conclusions from scheduler-level metrics.

---

# Final Conclusion

For a single Tesla T4 serving Phi-2 through vLLM:

- Peak throughput reached approximately **248 tokens/sec**
- Peak request throughput reached approximately **4 requests/sec**
- Reliability remained **100% successful**
- No errors were observed
- No memory pressure was observed

The practical saturation point occurred around:

```text
10 concurrent requests
```

Beyond that point, additional concurrency primarily increased waiting time and latency rather than throughput.

For the tested workload (short prompt, 128-token generation), neither `max_num_seqs` nor `max_num_batched_tokens` produced a significant performance improvement, suggesting that another serving constraint became dominant before those limits were reached.