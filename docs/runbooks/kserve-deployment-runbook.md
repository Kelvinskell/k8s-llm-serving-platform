# Runbook: KServe Deployment (RawDeployment)

## Purpose
- Operate stable phi-2 service deployed automatically by pipeline.
- Apply phi-3 canary manually.
- Verify health, inference, and metrics quickly.

## Scope
- Stable service: auto apply from kserve auto folder.
- Canary service: manual apply from kserve manual folder.
- Traffic split: handled later by Istio VirtualService.

## Prerequisites
- KServe, Knative, and Istio are installed and healthy.
- Namespace `llm-serving` exists.
- ServiceAccount `vllm-serving` exists.
- Model cache warmer is running on GPU nodes.
- Stable service manifest is applied.

## Quick Health Checks
```bash
kubectl get crd inferenceservices.serving.kserve.io
kubectl get pods -n kserve
kubectl get pods -n knative-serving
kubectl get pods -n istio-system
kubectl get inferenceservice -n llm-serving
kubectl get pods -n llm-serving
```

## Stable Validation
```bash
kubectl -n llm-serving port-forward svc/phi-chat-2-predictor 8000:80
curl -s http://127.0.0.1:8000/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-2","prompt":"Say hello in one short sentence.","max_tokens":64,"temperature":0.2}'

# Option 2: formatted JSON output
curl -s http://127.0.0.1:8000/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-2","prompt":"Say hello in one short sentence.","max_tokens":32,"temperature":0.2}' | jq .

# Option 3: only generated text
curl -s http://127.0.0.1:8000/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-2","prompt":"Say hello in one short sentence.","max_tokens":32,"temperature":0.2}' | jq -r '.choices[0].text'
```

## Metrics Validation
```bash
kubectl -n llm-serving get servicemonitor
kubectl -n llm-serving describe servicemonitor vllm-kserve-phi
kubectl -n llm-serving get svc -l serving.kserve.io/inferenceservice=phi-chat-2 --show-labels
kubectl -n llm-serving get svc -l serving.kserve.io/inferenceservice=phi-chat-3 --show-labels
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In Prometheus UI, open Status -> Targets and confirm KServe scrape targets are `UP`.

## Manual Phi-chat-3 Apply
```bash
kubectl apply -f kubernetes/serving/kserve/manual/phi-chat-3.yaml
kubectl -n llm-serving get inferenceservice phi-chat-3 -w
kubectl -n llm-serving get pods -l serving.kserve.io/inferenceservice=phi-chat-3 -w
kubectl -n llm-serving port-forward svc/phi-chat-3-predictor 8002:80
curl -s http://127.0.0.1:8002/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-3","prompt":"Say hello in one short sentence.","max_tokens":64,"temperature":0.2}'
```

## External Validation (VirtualService)
```bash
# Verify VirtualService objects are present
kubectl -n llm-serving get virtualservice

# Verify predictor endpoint is healthy
kubectl -n llm-serving get endpoints phi-chat-2-predictor

# Read external host value from InferenceService status
kubectl -n llm-serving get inferenceservice phi-chat-2 -o jsonpath='{.status.url}{"\n"}'

# Test via ALB with Host header (replace ALB_DNS)
curl -s http://ALB_DNS/v1/completions \
	-H "Host: phi-chat-2-llm-serving.example.com" \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-2","prompt":"Say hello in one short sentence.","max_tokens":32,"temperature":0.2}' | jq .
```

If external test returns 404 from istio-envoy, route matching is still missing or host does not match the VirtualService.

## External Quick Stress Test (5 Terminals)
Run the following in 5 separate terminals to generate concurrent traffic through ALB ingress.
These examples use completions API only for phi-2 and use longer prompts to put pressure on KV cache and scheduler queue depth.
If you call chat-completions for phi-2 without a configured chat template, vLLM returns HTTP 400.

```bash
for i in {1..1000}; do echo "T1 run $i"; curl -s http://<ALB_DNS>/v1/completions -H "Host: phi-chat-2-llm-serving.example.com" -H "Content-Type: application/json" -d "{\"model\":\"phi-2\",\"prompt\":\"You are a senior SRE for GPU inference systems. Write a structured incident note with context, hypotheses, checks, mitigations, and follow-ups for request $i. Include concrete operational details and at least 10 bullet points.\",\"max_tokens\":512,\"temperature\":0.25}" | jq .; done
```

```bash
for i in {1..1000}; do echo "T2 run $i"; curl -s http://<ALB_DNS>/v1/completions -H "Host: phi-chat-2-llm-serving.example.com" -H "Content-Type: application/json" -d "{\"model\":\"phi-2\",\"prompt\":\"You are an ML platform engineer focused on serving reliability. Design a capacity plan for multi-tenant LLM traffic with queueing assumptions, scaling thresholds, and risk controls. Request ID: $i\",\"max_tokens\":512,\"temperature\":0.35}" | jq .; done
```

```bash
for i in {1..1000}; do echo "T3 run $i"; curl -s http://<ALB_DNS>/v1/completions -H "Host: phi-chat-2-llm-serving.example.com" -H "Content-Type: application/json" -d "{\"model\":\"phi-2\",\"prompt\":\"Given a high-throughput chat API, explain latency decomposition across prefill and decode, list likely bottlenecks, and provide mitigation steps with brief justifications. Request ID: $i\",\"max_tokens\":512,\"temperature\":0.3}" | jq .; done
```

```bash
for i in {1..1000}; do echo "T4 run $i"; curl -s http://<ALB_DNS>/v1/completions -H "Host: phi-chat-2-llm-serving.example.com" -H "Content-Type: application/json" -d "{\"model\":\"phi-2\",\"prompt\":\"You are a distributed systems teacher. Explain queue growth, batching, and KV-cache pressure using concrete examples and action-oriented guidance. Request ID: $i\",\"max_tokens\":512,\"temperature\":0.4}" | jq .; done
```

```bash
for i in {1..1000}; do echo "T5 run $i"; curl -s http://<ALB_DNS>/v1/completions -H "Host: phi-chat-2-llm-serving.example.com" -H "Content-Type: application/json" -d "{\"model\":\"phi-2\",\"prompt\":\"Create a troubleshooting checklist for degraded LLM latency with Prometheus signals, pod-level checks, and rollback criteria. Keep it detailed and structured. Request ID: $i\",\"max_tokens\":512,\"temperature\":0.3}" | jq .; done
```

## Scaling Expectation
- Current architecture uses KServe-managed autoscaling for `phi-chat-2` and does not depend on Karpenter scale-out.
- `phi-chat-3` can stay `Pending` when GPU/cpu capacity is exhausted or node selectors/tolerations cannot be satisfied.
- This is expected in the current design when no node autoscaler is available to add new GPU nodes.
- I observed at least one successful Karpenter node provisioning event during load, but scaling behavior was not reliable while HPA ownership was conflicting.

## Known Behavior and Incidents
- I observed autoscaling conflicts when both KServe HPA and KEDA HPA targeted `phi-chat-2-predictor`.
- Symptom: `AmbiguousSelector` and scale up/down thrashing in HPA events.
- Observed behavior: replicas briefly scaled up (for example, to 2) and then were forced back down to 1 by the competing HPA.
- Observed behavior: Karpenter did provision an additional self-managed GPU node at least once, but demand was not sustained because replicas were scaled back down.
- Resolution: keep KServe as the only autoscaler owner for KServe-managed predictors.
- I also observed `phi-chat-3` pending due to scheduling constraints while no node autoscaler was available.
- Operational impact: queue depth can increase while replicas stay constrained by existing node capacity.

Use these checks during incidents:

```bash
kubectl -n llm-serving get hpa
kubectl -n llm-serving get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n llm-serving get pods -o wide
kubectl get nodes
```

## Rollback
If canary misbehaves, remove canary service:

```bash
kubectl -n llm-serving delete inferenceservice phi-chat-3
```

If traffic split is configured in Istio, set canary destination weight to 0.

## Operations Notes
- Stable service is pipeline-managed from `kubernetes/serving/kserve/auto`.
- Canary service is manual by design.
- Current architecture favors one pod per GPU for predictable behavior and safer canary evaluation.
