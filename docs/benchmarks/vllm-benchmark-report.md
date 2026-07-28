# TinyLlama vLLM Benchmark

## Environment
- EKS
- vLLM
- TinyLlama
- NVIDIA T4
- Prometheus/Grafana

## Test Scenarios
- Concurrency: 1, 5, 10, 20, 40
- Small/Medium/Large prompts

## Results
- Peak throughput: X req/s
- Saturation point: Y concurrent users
- TTFT range: A ms → B ms
- Max GPU utilization: Z%

## Bottlenecks
- GPU saturation
- Queue buildup
- Memory pressure

## Optimizations
- Adjusted batching
- Tuned concurrency
- Added autoscaling

## Lessons Learned
- Throughput stopped scaling past ...
- TTFT degraded sharply after ...
- GPU utilization was the primary limiting factor