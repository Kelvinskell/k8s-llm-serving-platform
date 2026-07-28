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

## Manual Canary Apply
```bash
kubectl apply -f kubernetes/serving/kserve/manual/phi-chat-canary.yaml
kubectl -n llm-serving get inferenceservice phi-chat-3 -w
kubectl -n llm-serving get pods -l serving.kserve.io/inferenceservice=phi-chat-3 -w
kubectl -n llm-serving port-forward svc/phi-chat-3-predictor 8002:80
curl -s http://127.0.0.1:8002/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-3","prompt":"Say hello in one short sentence.","max_tokens":64,"temperature":0.2}'
```

## Canary Expectation
- Canary (`phi-chat-3`) is expected to run on a new GPU node provisioned by Karpenter, not colocated with stable (`phi-chat-2`) on the same GPU.
- If canary stays `Pending`, verify Karpenter scale-out before changing model settings.

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
