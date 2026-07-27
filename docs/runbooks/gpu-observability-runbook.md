# GPU Observability Runbook

## Purpose
This runbook is the operational reference for GPU observability on this Kubernetes platform. It covers the Prometheus recording rules, alert rules, and the basic commands used to verify that GPU metrics are available and alerts are functioning.

## Prerequisites
- The EKS cluster is reachable from your shell.
- The monitoring namespace exists.
- kube-prometheus-stack is deployed.
- The DCGM exporter is deployed and scraping GPU metrics.

## Related Files
- [../../kubernetes/base/monitoring/gpu-recording-rules.yaml](../../kubernetes/base/monitoring/gpu-recording-rules.yaml)
- [../../kubernetes/base/monitoring/gpu-alert-rules.yaml](../../kubernetes/base/monitoring/gpu-alert-rules.yaml)

## Key Rules
- `platform_gpu_utilization_5m`
  - 5-minute average GPU utilization
- `platform_gpu_memory_used_ratio_5m`
  - 5-minute average GPU memory usage percentage
- `GpuHighUtilization`
  - fires when average GPU utilization exceeds 85% for 10 minutes
- `GpuHighMemoryPressure`
  - fires when average GPU memory usage exceeds 90% for 10 minutes
- `DcgmExporterDown`
  - fires when the DCGM exporter target is down

## Verify the Rule Objects Exist
```bash
kubectl -n monitoring get prometheusrule
kubectl -n monitoring describe prometheusrule gpu-observability-recording-rules
kubectl -n monitoring describe prometheusrule gpu-observability-alert-rules
```

## Verify Prometheus Can See Them
```bash
kubectl -n monitoring get prometheus
kubectl -n monitoring get pods
```

## Grafana Access
Port-forward Grafana locally:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 8080:80
```

Open:

```text
http://127.0.0.1:8080
```

Get Grafana admin username and password from the monitoring namespace secret:

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-user}' | base64 --decode; echo
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

## Validate the Prometheus Expressions
Use the Prometheus UI or query endpoint to test these expressions:

```promql
avg_over_time(DCGM_FI_DEV_GPU_UTIL[10m]) > 85
```

```promql
100 * avg_over_time(DCGM_FI_DEV_FB_USED[10m]) / clamp_min(avg_over_time(DCGM_FI_DEV_FB_USED[10m]) + avg_over_time(DCGM_FI_DEV_FB_FREE[10m]), 1) > 90
```

```promql
up{job="dcgm-exporter"} == 0
```

## Troubleshooting
### Rules are not appearing
- Confirm the PrometheusRule has the `release: kube-prometheus-stack` label.
- Confirm the Prometheus CR is in the monitoring namespace and has the expected rule selector.

### Alerts are not firing
- Confirm the DCGM exporter target is present and healthy.
- Validate the expression manually in Prometheus.
- Check that the metrics exist by querying the raw DCGM metric names directly.

## Notes
This runbook is intentionally operational. It is meant for day-to-day verification and troubleshooting rather than project planning or phase tracking.
