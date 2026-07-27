# Runbook: Manual vLLM Serving Validation (TinyLlama)

## Purpose
This runbook documents how to manually deploy and validate the vLLM baseline serving stack.

This stack is intentionally applied manually and is not wired into the Kubernetes CI pipeline yet, because the primary serving automation path in later phases will be KServe.

## Scope
This runbook covers:
- Applying manifests from `kubernetes/serving/vllm`
- Verifying pod and service health
- Port-forwarding for local testing
- Sending OpenAI-compatible requests with curl
- Understanding request arguments and response fields
- Verifying Prometheus scraping and basic GPU correlation
- Common troubleshooting steps

## Related Manifests
- `kubernetes/serving/vllm/tinyllama-sa.yaml`
- `kubernetes/serving/vllm/tinyllama-deployment.yaml`
- `kubernetes/serving/vllm/tinyllama-svc.yaml`
- `kubernetes/serving/vllm/tinyllama-servicemonitor.yaml`

## Prerequisites
- `kubectl` context points to the target EKS cluster.
- Namespace `llm-serving` exists.
- GPU node group is online and schedulable.
- NVIDIA device plugin is healthy.
- Model cache is already populated on the target GPU node under `/var/lib/llm-model-cache`.
- kube-prometheus-stack is deployed in namespace `monitoring`.

## Step 1: Deploy vLLM Manifests
Apply all resources from the vLLM folder:

```bash
kubectl apply -f kubernetes/serving/vllm/
```

Check created resources:

```bash
kubectl -n llm-serving get sa,deploy,svc,servicemonitor
```

Wait for rollout:

```bash
kubectl -n llm-serving rollout status deploy/vllm-tinyllama
```

## Step 2: Basic Runtime Verification
Check pod status and placement:

```bash
kubectl -n llm-serving get pods -o wide
```

Inspect deployment events if startup is slow:

```bash
kubectl -n llm-serving describe deploy vllm-tinyllama
kubectl -n llm-serving get events --sort-by=.lastTimestamp | tail -n 40
```

Stream logs:

```bash
kubectl -n llm-serving logs -f deploy/vllm-tinyllama
```

Healthy pattern in logs:
- Application startup completes.
- `/health` returns HTTP 200.
- Model load finishes without CrashLoop/OOM.

## Step 3: Port-Forward for Local Testing
Run in a dedicated terminal and keep it open:

```bash
kubectl -n llm-serving port-forward svc/vllm-tinyllama 8000:8000
```

Quick health check:

```bash
curl -i http://127.0.0.1:8000/health
```

Expected: `HTTP/1.1 200 OK`

## Step 4: Send Inference Requests (OpenAI-Compatible API)
Minimal request (required fields only):

```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Hello"}]}' | jq
```

Baseline request with generation controls:

```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama","messages":[{"role":"system","content":"You are helpful."},{"role":"user","content":"Say hello in one sentence."}],"max_tokens":80,"temperature":0.7}' | jq
```

If `jq` is not installed:

```bash
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"tinyllama","messages":[{"role":"user","content":"Hello"}]}' | python3 -m json.tool
```

## Step 4.1: Quick Stress Test (5 Terminals)
Run the following in 5 separate terminals while port-forward on `:8000` is active.

Terminal 1:
```bash
for i in {1..1000}; do echo "T1 run $i"; curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a senior SRE for GPU inference systems.\"},{\"role\":\"user\",\"content\":\"Write a full post-incident report for a production LLM outage with timeline, blast radius, telemetry interpretation, root cause tree, rollback, remediation, and prevention. Include deep technical detail and at least 40 concrete action items. Request ID: $i\"}],\"max_tokens\":1000,\"temperature\":0.7}" | jq; done
```

Terminal 2:
```bash
for i in {1..1000}; do echo "T2 run $i"; curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"system\",\"content\":\"You are an ML platform engineer.\"},{\"role\":\"user\",\"content\":\"Design a capacity planning document for multi-tenant LLM serving on shared GPUs. Include traffic classes, queueing model, scaling thresholds, SLO math, and cost-performance tradeoffs with concrete examples. Request ID: $i\"}],\"max_tokens\":1000,\"temperature\":0.75}" | jq; done
```

Terminal 3:
```bash
for i in {1..1000}; do echo "T3 run $i"; curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a principal backend architect.\"},{\"role\":\"user\",\"content\":\"Produce an architecture review for high-throughput chat API serving with Kubernetes and vLLM. Cover request lifecycle, bottlenecks, memory behavior, latency decomposition, and mitigations in depth. Request ID: $i\"}],\"max_tokens\":1000,\"temperature\":0.8}" | jq; done
```

Terminal 4:
```bash
for i in {1..1000}; do echo "T4 run $i"; curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a distributed systems professor.\"},{\"role\":\"user\",\"content\":\"Explain queueing, batching, token scheduling, and KV-cache pressure in LLM inference with numerical examples and step-by-step derivations. Request ID: $i\"}],\"max_tokens\":1000,\"temperature\":0.85}" | jq; done
```

Terminal 5:
```bash
for i in {1..1000}; do echo "T5 run $i"; curl -s http://127.0.0.1:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tinyllama\",\"messages\":[{\"role\":\"system\",\"content\":\"You are a staff reliability engineer.\"},{\"role\":\"user\",\"content\":\"Create a runbook for diagnosing severe latency regressions in LLM inference, including triage flow, Prometheus queries, dashboard interpretation, pod checks, GPU diagnostics, and rollback criteria. Request ID: $i\"}],\"max_tokens\":1000,\"temperature\":0.7}" | jq; done
```

## Step 5: Understand Request Arguments
Required:
- `model`: API model name to route request to (must match served model name).
- `messages`: chat history array.

Common optional controls:
- `max_tokens`: maximum generated output tokens.
- `temperature`: sampling randomness; lower is more deterministic.
- `top_p`: nucleus sampling; alternative/companion to temperature.
- `stream`: if `true`, response is token-streamed.

Deployment-side serving flags in this project:
- Positional model path: `/models/TinyLlama/TinyLlama-1.1B-Chat-v1.0/main`
- `--served-model-name tinyllama`
- `--gpu-memory-utilization 0.85`
- `--max-num-seqs 16`

Notes:
- `--served-model-name` is the request-facing name (`"model":"tinyllama"`).
- The positional model path is the local filesystem path loaded by vLLM.

## Step 6: Understand Response Fields
Example key fields:
- `id`: unique completion identifier.
- `object`: response type (`chat.completion`).
- `model`: model name that served the request.
- `choices[0].message.content`: generated text.
- `choices[0].finish_reason`: why generation stopped (`stop`, `length`, etc.).
- `usage.prompt_tokens`: input token count.
- `usage.completion_tokens`: generated token count.
- `usage.total_tokens`: total token count.

Interpretation examples:
- `finish_reason: "stop"`: normal completion.
- `finish_reason: "length"`: hit token limit (often `max_tokens`).
- Error response with unknown model: request model does not match served name.

## Step 7: Prometheus and ServiceMonitor Verification
Ensure ServiceMonitor exists:

```bash
kubectl -n llm-serving get servicemonitor vllm-tinyllama -o yaml
```

Ensure Prometheus is selecting ServiceMonitors cluster-wide:

```bash
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus -o yaml | grep -E "serviceMonitorSelector|serviceMonitorNamespaceSelector"
```

Port-forward Prometheus:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In Prometheus UI, validate:
- Target state for vLLM or service monitor endpoint is `UP`.
- Query `/metrics` based series (vLLM metrics names can vary by version).

GPU correlation query examples:

```promql
DCGM_FI_DEV_GPU_UTIL{exported_namespace="llm-serving", exported_pod=~"vllm-tinyllama-.*"}
```

```promql
avg_over_time(DCGM_FI_DEV_GPU_UTIL{exported_namespace="llm-serving", exported_pod=~"vllm-tinyllama-.*"}[5m])
```

```promql
DCGM_FI_DEV_FB_USED{exported_namespace="llm-serving", exported_pod=~"vllm-tinyllama-.*"}
```

Important behavior:
- `FB_USED` can stay high at idle because memory is reserved.
- `GPU_UTIL` may still be near 0 if no active token generation is happening at scrape time.

## Troubleshooting
### Symptom: `curl` exits with code 7
Cause:
- Local port-forward to `:8000` is not active.

Fix:
```bash
kubectl -n llm-serving port-forward svc/vllm-tinyllama 8000:8000
```

### Symptom: `model not found` in response
Cause:
- Request `model` does not match `--served-model-name`.

Fix:
- Use `"model":"tinyllama"` for this deployment.
- Check available models:
```bash
curl -s http://127.0.0.1:8000/v1/models | jq
```

### Symptom: Pod pending on scheduling
Cause candidates:
- No GPU capacity.
- Node selector mismatch.
- Taint/toleration mismatch.

Fix:
```bash
kubectl -n llm-serving describe pod <pod-name>
kubectl get nodes -L eks.amazonaws.com/nodegroup
```

### Symptom: Startup fails due to missing model files
Cause:
- Host cache path does not contain expected model files on the node where pod landed.

Fix:
- Re-run model cache warmer.
- Confirm path on node: `/var/lib/llm-model-cache/TinyLlama/TinyLlama-1.1B-Chat-v1.0/main`

### Symptom: High GPU memory but low GPU utilization
Meaning:
- Model and cache are loaded/reserved, but there is little or no active inference traffic.

Fix:
- Generate sustained load and query windowed utilization (`avg_over_time`, `max_over_time`).

### Symptom: noisy `Unknown VLLM_*` env warnings
Cause:
- Kubernetes service link env vars can look like vLLM env vars.

Fix in this project:
- `enableServiceLinks: false` is already set in the deployment.

## Cleanup
```bash
kubectl delete -f kubernetes/serving/vllm/
```

## Evidence to Capture for Phase 4
- Deployment rollout success output.
- vLLM startup log snippet showing `/health` 200.
- Example successful curl response.
- Prometheus target status screenshot or output.
- GPU metric query snapshot during active inference load.
