# Autoscaling Decision Record

## Decision
- Keep KServe as the autoscaling owner for KServe-managed InferenceServices.
- Do not use KEDA to scale the same predictor Deployment managed by KServe.
- Do not rely on Karpenter for this phase of the project architecture.

## What We Encountered
- KEDA and KServe both created HPAs for `phi-chat-2-predictor`.
- This caused `AmbiguousSelector` warnings and scaling thrash (scale up and immediate scale down).
- During load, queue depth increased but scaling behavior was unstable while two HPAs competed.

## Why Karpenter Did Not Scale
- Karpenter scales nodes only when there are unschedulable pods.
- During HPA conflict, replica intent changed rapidly and did not produce stable provisioning behavior.
- In the final architecture decision, node autoscaler scale-out is not a dependency for this phase.

## Phi-Chat-3 Behavior in Current Architecture
- `phi-chat-3` may remain `Pending` when existing nodes cannot satisfy scheduling constraints.
- Without node scale-out, pending pods are expected until capacity is available.
- This is an accepted trade-off for predictable KServe-first operations in this phase.

## Operational Rules
- One predictor Deployment must have only one HPA owner.
- For KServe-managed predictors, keep KServe HPA and remove overlapping KEDA ScaledObjects.

## Verification Commands
```bash
kubectl -n llm-serving get hpa
kubectl -n llm-serving get inferenceservice
kubectl -n llm-serving get pods -o wide
kubectl -n llm-serving get events --sort-by=.lastTimestamp | tail -n 40
kubectl get nodes
```
