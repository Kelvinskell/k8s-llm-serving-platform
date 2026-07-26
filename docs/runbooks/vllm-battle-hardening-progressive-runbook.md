# Runbook: Progressive vLLM Battle Hardening

## Purpose
This runbook is for deep operator training, not just demo completion. It is designed to build real inference engineering instincts for vLLM on GPU with Prometheus-based observability.

Use this runbook in order, from Stage 0 through Stage 9.

## Scope
You will practice:
- Metric literacy
- Throughput and latency tuning
- Saturation and overload behavior
- Queueing and backpressure behavior
- GPU memory and KV cache pressure behavior
- Replica scaling behavior under time-slicing
- Troubleshooting and incident-style diagnosis

## Related References
- [docs/runbooks/dcgm-prometheus-metrics-reference.md](docs/runbooks/dcgm-prometheus-metrics-reference.md)
- [docs/runbooks/vllm-prometheus-metrics-reference.md](docs/runbooks/vllm-prometheus-metrics-reference.md)
- [kubernetes/base/monitoring/gpu-recording-rules.yaml](kubernetes/base/monitoring/gpu-recording-rules.yaml)
- [kubernetes/base/monitoring/gpu-alert-rules.yaml](kubernetes/base/monitoring/gpu-alert-rules.yaml)
- [docs/runbooks/vllm-manual-serving-runbook.md](docs/runbooks/vllm-manual-serving-runbook.md)

## Stage 0: Baseline Metric Literacy (Mandatory First Step)
Goal: run all existing Prometheus queries from your references and understand each signal before any stress test.

### 0.1 Run all DCGM metric queries from the metrics reference
Run and record values for:
- DCGM_FI_DEV_GPU_UTIL
- DCGM_FI_DEV_FB_USED
- DCGM_FI_DEV_FB_FREE
- 100 * DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE)
- DCGM_FI_DEV_GPU_TEMP
- DCGM_FI_DEV_POWER_USAGE
- DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION
- DCGM_FI_DEV_SM_CLOCK
- DCGM_FI_DEV_MEM_CLOCK
- avg_over_time(DCGM_FI_DEV_GPU_UTIL[5m])
- DCGM_FI_PROF_PIPE_TENSOR_ACTIVE
- DCGM_FI_PROF_DRAM_ACTIVE
- DCGM_FI_PROF_GR_ENGINE_ACTIVE
- DCGM_FI_PROF_PCIE_TX_BYTES
- DCGM_FI_PROF_PCIE_RX_BYTES
- DCGM_FI_DEV_MEM_COPY_UTIL
- avg_over_time(DCGM_FI_PROF_PIPE_TENSOR_ACTIVE[5m])
- max_over_time(DCGM_FI_DEV_GPU_UTIL[5m])
- max_over_time(DCGM_FI_DEV_FB_USED[5m])
- avg_over_time(DCGM_FI_DEV_POWER_USAGE[5m])

Checklist:
- [ ] Idle snapshot captured
- [ ] Under-load snapshot captured
- [ ] Per-query interpretation written in your notes

### 0.2 Run all recording rule metrics
Run and record values for:
- platform_gpu_utilization_5m
- platform_gpu_memory_used_ratio_5m
- platform_gpu_memory_peak_5m
- platform_gpu_power_avg_5m
- platform_gpu_temperature_avg_5m

Checklist:
- [ ] Recording rules return data
- [ ] Values are directionally consistent with raw DCGM metrics
- [ ] You can explain why recording rule values differ from raw instantaneous values

### 0.3 Confirm alerts are understandable
Review and evaluate:
- GpuHighUtilization
- GpuHighMemoryPressure
- DcgmExporterDown

Checklist:
- [ ] You know exact trigger threshold and for-duration for each alert
- [ ] You can describe one false-positive scenario and one true-positive scenario for each alert

## Stage 1: vLLM Metric Discovery and Label Mapping
Goal: identify all vLLM series available in your current build and map them to pod, namespace, and model dimensions.

Run in Prometheus:
- {__name__=~"vllm.*"}
- {__name__=~".*request.*"}
- {__name__=~".*token.*"}
- {__name__=~".*queue.*|.*pending.*"}
- {__name__=~".*kv.*cache.*|.*cache.*kv.*"}

Checklist:
- [ ] You have a list of available vLLM metric names
- [ ] You identified request count metric
- [ ] You identified latency metric(s)
- [ ] You identified queue depth or pending request metric
- [ ] You identified KV cache-related metric(s)

### 1.1 Required Metric Contract (Lock Before Stage 2)
Map your live metric names to these required signals and keep this mapping in your experiment notes:
- GPU Utilization %
- GPU Memory %
- KV Cache Usage %
- Request Throughput
- P99 Latency
- Prefill Latency
- Decode Latency
- Pending Requests
- Preemption Count

Checklist:
- [ ] All required signals are mapped to real metric names in your cluster
- [ ] Every signal can be queried by pod and by time range

## Stage 2: Build a Clean Baseline Experiment
Goal: measure one stable baseline before changing tuning knobs.

Baseline config example:
- Replicas: 1
- gpu-memory-utilization: 0.85
- max-num-seqs: 16
- Fixed prompt set: short and medium
- Fixed duration per run: 5 to 10 minutes

Collect:
- TTFT p50/p95
- End-to-end latency p99
- Prefill latency
- Decode latency
- Tokens per second
- Request success rate
- GPU util average and peak
- GPU memory used ratio
- KV cache usage %
- FB used average and peak
- Queue depth average and peak
- Pending requests average and peak
- Preemption count

Checklist:
- [ ] Baseline run completed
- [ ] Baseline metric table written
- [ ] No ambiguity on what “healthy” means for this baseline

## Stage 3: Controlled Overload Drills
Goal: intentionally push past capacity to learn failure signatures.

Overload pattern:
- Keep model fixed
- Increase concurrent clients in steps: 1, 2, 4, 8, 16, 24
- Keep request payload constant during each step

Observe and mark the first point where each occurs:
- p95 latency cliff
- p99 latency cliff
- prefill latency spike
- decode latency spike
- Queue depth sustained growth
- Pending requests sustained growth
- Throughput flattening
- Error rate rise
- Preemption count rise
- KV cache usage approaching saturation
- GPU util pinned high

Checklist:
- [ ] Saturation point identified
- [ ] First failing signal identified
- [ ] Dominant bottleneck hypothesis written

## Stage 4: Knob Sweep for Sweet Spot
Goal: find best stable operating zone, not max possible burst.

Sweep matrix:
- gpu-memory-utilization: 0.20, 0.25, 0.30
- max-num-seqs: 4, 8, 16
- replicas: 1 then 2

For each cell, run identical workload and record:
- TTFT p95
- End-to-end latency p99
- Prefill latency
- Decode latency
- Throughput
- Error rate
- Queue behavior
- Pending requests
- Preemption count
- KV cache usage %
- GPU memory pressure

Stop criteria for a bad cell:
- Frequent OOM or restarts
- Sustained queue growth
- Error rate above acceptable threshold

Checklist:
- [ ] Matrix executed
- [ ] Best configuration selected
- [ ] Clear trade-off statement written

### 4.1 Advanced vLLM Engine Knob Drills (Required)
Goal: understand scheduler, KV cache, and memory spill behavior using core vLLM runtime flags.

Run these drills one knob at a time. Keep workload and prompt mix unchanged across runs.

Knobs to include:
- `--max-model-len`
- `--max-num-batched-tokens`
- `--enforce-eager`
- `--kv-cache-dtype`
- `--swap-space`
- `--enable-prefix-caching`

Recommended test order and values:
- `max-model-len`: 1024, 2048, 4096
- `max-num-batched-tokens`: 512, 1024, 2048
- `enforce-eager`: false, true
- `kv-cache-dtype`: auto, fp8
- `swap-space`: 0, 4, 8 (GiB)
- `enable-prefix-caching`: false, true

What each knob teaches:
- `max-model-len`: controls context ceiling and KV cache pressure.
- `max-num-batched-tokens`: controls batch packing aggressiveness and queue drain behavior.
- `enforce-eager`: disables graph capture optimizations and helps isolate compiler-related variance.
- `kv-cache-dtype`: trades KV precision for memory headroom.
- `swap-space`: enables CPU spill when KV pressure grows, with latency trade-offs.
- `enable-prefix-caching`: improves repeated-prefix workloads, especially chat-style prompts.

Signals to capture for every run:
- TTFT p50/p95
- End-to-end latency p99
- Prefill latency
- Decode latency
- Tokens per second
- Error rate
- Queue depth average/peak
- Pending requests average/peak
- Preemption count
- KV cache usage %
- GPU memory used ratio
- GPU utilization average/peak

Expected failure signatures to watch:
- Too high `max-model-len`: high VRAM pressure, earlier OOM, degraded concurrency.
- Too high `max-num-batched-tokens`: latency spikes and queue jitter.
- `enforce-eager=true` regressions: lower throughput, higher TTFT.
- Aggressive `kv-cache-dtype` mismatch: potential quality instability or unsupported-path errors.
- High `swap-space` dependence: tail-latency inflation under load.
- Prefix cache disabled on repeated prompts: avoidable TTFT increase.

Checklist:
- [ ] All six knobs tested with controlled A/B runs
- [ ] Best value selected per knob
- [ ] Final combined profile validated under sustained load
- [ ] Trade-off notes written for quality, latency, and memory

## Stage 5: Replica Behavior and Time-Slicing Reality
Goal: learn what changes with 2 replicas on shared GPU slices.

Experiments:
- 1 replica with conservative memory setting
- 2 replicas with same setting
- Compare fairness and tail latency

Focus questions:
- Does aggregate throughput improve meaningfully?
- Does TTFT p95 degrade disproportionately?
- Does one replica starve while the other succeeds?

Checklist:
- [ ] 1 replica vs 2 replica comparison completed
- [ ] Time-slicing side effects documented
- [ ] Recommendation recorded for your hardware profile

## Stage 6: Incident Simulation and Troubleshooting
Goal: practice battle drills under realistic breakage.

Inject and diagnose scenarios:
- Remove or break port-forward and recover quickly
- Deliberately use wrong model name in request and trace error path
- Temporarily reduce gpu-memory-utilization too far and observe throughput loss
- Temporarily increase max-num-seqs too high and observe queueing or memory pressure
- Simulate exporter outage impact by tracing missing metrics symptoms

For each incident, produce:
- Symptom
- First metric that revealed it
- Root cause
- Fix
- Prevention guardrail

Checklist:
- [ ] At least 5 incident cards completed
- [ ] Mean time to detect and mean time to recover tracked

## Stage 7: Build an Operator Dashboard View
Goal: build one battle console for fast decisions.

Required panels:
- Traffic: request rate and errors
- Latency: TTFT p50/p95, end-to-end p99, prefill latency, decode latency
- Throughput: tokens per second
- Queue: pending depth and preemption count
- KV cache: usage percentage and pressure trend
- GPU: util, memory percentage, temperature, power
- Capacity: per-replica comparison if replicas > 1

Checklist:
- [ ] Dashboard includes all required dimensions
- [ ] Single-screen triage flow works in live load test

## Stage 8: Define Production-Like Acceptance Gates
Goal: formalize what “production-like” means for your environment.

Define hard gates:
- Availability target
- p95 TTFT target
- p99 latency target
- prefill latency target
- decode latency target
- Error-rate ceiling
- pending request ceiling
- preemption count ceiling
- KV cache usage safety ceiling
- Sustained load duration target
- Alerting quality target

Checklist:
- [ ] Gates documented
- [ ] Current setup evaluated against all gates
- [ ] Gaps and remediation plan written

## Stage 9: Publish Evidence Pack
Goal: turn hands-on work into reusable engineering proof.

Capture:
- Final tested deployment config
- Experiment matrix results
- Saturation charts
- Incident cards
- Dashboard screenshots
- Final operating recommendation

Store in:
- [load-testing/results](load-testing/results)

Checklist:
- [ ] Evidence committed
- [ ] Summary write-up complete


## Fast Command Pack
Apply serving manifests:

`kubectl apply -f kubernetes/serving/vllm/`

Restart and watch rollout:

`kubectl -n llm-serving rollout restart deploy/vllm-tinyllama`
`kubectl -n llm-serving rollout status deploy/vllm-tinyllama`

Watch logs:

`kubectl -n llm-serving logs -f deploy/vllm-tinyllama`

Port-forward vLLM endpoint:

`kubectl -n llm-serving port-forward svc/vllm-tinyllama 8000:8000`

Smoke test inference:

`curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"tinyllama","messages":[{"role":"user","content":"hello"}]}' | jq`

Port-forward Prometheus:

`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090`

## Notes for Your Current Hardware Profile
- T4 with time-slicing can look healthy at low load and collapse at moderate concurrency if memory and queue knobs are too aggressive.
- High FB_USED with low GPU_UTIL can be normal at idle for vLLM due to reservation behavior.
- The sweet spot is usually lower gpu-memory-utilization with disciplined max-num-seqs when sharing one physical GPU.
