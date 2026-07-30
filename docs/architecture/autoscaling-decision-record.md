# Autoscaling Decision Record

## Status
- Superseded by the 2026-07-30 decision below for `phi-chat-2`.

## Decision
- Keep KServe as the autoscaling owner for KServe-managed InferenceServices.
- Do not use KEDA to scale the same predictor Deployment managed by KServe.
- Do not rely on Karpenter for this phase of the project architecture.

## Superseding Decision (2026-07-30)
- For `phi-chat-2`, use KEDA as the autoscaling owner.
- Keep `InferenceService` in Raw/Standard deployment mode, but set `serving.kserve.io/autoscalerClass: external` so KServe does not own HPA for this predictor.
- Keep one autoscaling owner per target Deployment (`phi-chat-2-predictor`): KEDA only.

## Why This Changed
- KServe documentation explicitly supports disabling KServe-managed HPA in Standard/Raw path by setting `serving.kserve.io/autoscalerClass` to `external` (or `none`).
- This allows an external autoscaler to manage the workload without KServe HPA ownership conflict.

## Source Documentation
- KServe HPA autoscaler doc (Disable HPA in Standard Deployment):
	- https://kserve.github.io/website/docs/model-serving/predictive-inference/autoscaling/hpa-autoscaler
- KServe KEDA autoscaler doc (annotation patterns and KEDA behavior):
	- https://kserve.github.io/website/docs/model-serving/predictive-inference/autoscaling/keda-autoscaler

## Evidence (2026-07-30)
- `ScaledObject` created and Ready:
	- `phi-chat-2-scaledobject   apps/v1.Deployment   phi-chat-2-predictor   ...   READY=True`
- HPA ownership moved to KEDA:
	- `keda-hpa-phi-chat-2-scaledobject   Deployment/phi-chat-2-predictor`
- No KServe-owned HPA appeared in `kubectl get hpa` after applying `autoscalerClass: external`.

## What I Encountered
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
