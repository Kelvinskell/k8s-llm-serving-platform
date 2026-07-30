# k8s-llm-serving-platform
**Kubernetes-native LLM serving platform focused on high throughput, GPU efficiency, autoscaling, and full-stack observability with vLLM, KServe, Prometheus, and Grafana.**

![Platform architecture diagram](docs/architecture/k8s-llm-serving-vllm.png)

## 1. Architecture At A Glance

This platform delivers GPU-backed LLM inference on EKS with KServe and vLLM, automated by Terraform and GitHub Actions. It includes model pre-warming, autoscaling controls, and end-to-end observability for GPU and inference behavior.

- Architecture doc: [docs/architecture/platform-architecture.md](docs/architecture/platform-architecture.md)
- Diagram source: [docs/architecture/platform-architecture-diagram.md](docs/architecture/platform-architecture-diagram.md)

## 2. Repository Structure

```text
.
├── docs/
│   ├── architecture/      # Architecture write-ups and decision records
│   ├── benchmarks/        # Benchmark analysis and conclusions
│   ├── dashboards/        # Dashboard screenshots and evidence
│   ├── roadmap/           # Project roadmap and phase plan
│   └── runbooks/          # Operational and troubleshooting runbooks
├── kubernetes/
│   ├── base/              # Namespace, storage/cache, monitoring rules
│   ├── serving/           # KServe and manual vLLM manifests
│   └── autoscaling/       # ScaledObject manifest(s)
├── load-testing/
│   ├── scripts/           # Benchmark orchestrator and Python tooling
│   └── results/           # CSV summaries and request-level artifacts
├── scenarios/             # Reproducible scenario manifests
├── terraform/
│   ├── envs/dev/          # Dev environment composition
│   ├── envs/stage/        # Stage environment scaffold
│   └── modules/           # Reusable Terraform modules
└── .github/workflows/     # CI/CD pipelines
```

## 3. Quick Start (Dev Environment)

### Prerequisites

- AWS account with EKS, IAM, and VPC permissions
- Terraform, kubectl, jq, curl, python3
- GitHub Actions OIDC configured for AWS
- kubeconfig access to the target EKS cluster

### Infrastructure Provisioning

```bash
cd terraform/envs/dev
terraform init
terraform plan
terraform apply
```

- Dev environment entrypoint: [terraform/envs/dev/main.tf](terraform/envs/dev/main.tf)
- Input variables: [terraform/envs/dev/variables.tf](terraform/envs/dev/variables.tf)

#### Safe Teardown Order

Terraform destroy can hang because of Kubernetes dependencies. To safely destroy, it's strongly advised to disable platform add-ons first. This is the recommended order:

```bash
cd terraform/envs/dev
terraform apply -auto-approve \
	-var="enable_kserve_module=false" \
	-var="enable_keda_module=false" \
	-var="enable_observability=false" \
	-var="enable_nvidia_device_plugin=false" && \
terraform destroy -auto-approve -target=module.karpentar && \
terraform destroy -auto-approve
```

You can also use the Kubernetes pipeline delete option for teardown: [.github/workflows/kubernetes-pipeline.yml](.github/workflows/kubernetes-pipeline.yml).
Select the delete path there when you want CI-driven cleanup instead of running the commands manually.

### Workload Deployment

```bash
kubectl apply -f kubernetes/base/namespaces
kubectl apply -f kubernetes/base/storage
kubectl apply -f kubernetes/base/monitoring
kubectl apply -f kubernetes/serving/kserve/auto
kubectl apply -f kubernetes/autoscaling
```

### Smoke Test Inference

```bash
kubectl -n llm-serving port-forward svc/phi-chat-2-predictor 8000:80
curl -s http://127.0.0.1:8000/v1/completions \
	-H "Content-Type: application/json" \
	-d '{"model":"phi-2","prompt":"Hello","max_tokens":32,"temperature":0.2}' | jq .
```

## 4. Deployment Model

### CI/CD Pipelines

- Terraform pipeline: [.github/workflows/terraform-pipeline.yml](.github/workflows/terraform-pipeline.yml)
- Kubernetes pipeline: [.github/workflows/kubernetes-pipeline.yml](.github/workflows/kubernetes-pipeline.yml)

GitHub Actions requires AWS OIDC trust plus a deploy IAM role with permissions for Terraform and EKS operations. Configure your repository secrets/variables to use that role before running either pipeline.

### Serving Paths

- Primary serving path (auto manifests): [kubernetes/serving/kserve/auto/phi-chat-2.yaml](kubernetes/serving/kserve/auto/phi-chat-2.yaml)
- Manual KServe variant: [kubernetes/serving/kserve/manual/phi-chat-3.yaml](kubernetes/serving/kserve/manual/phi-chat-3.yaml)
- Manual baseline vLLM deployment: [kubernetes/serving/vllm/tinyllama-deployment.yaml](kubernetes/serving/vllm/tinyllama-deployment.yaml)

## 5. Operations And Runbooks

### Core Runbooks

- KServe deployment and checks: [docs/runbooks/kserve-deployment-runbook.md](docs/runbooks/kserve-deployment-runbook.md)
- Manual vLLM serving: [docs/runbooks/vllm-manual-serving-runbook.md](docs/runbooks/vllm-manual-serving-runbook.md)
- GPU observability: [docs/runbooks/gpu-observability-runbook.md](docs/runbooks/gpu-observability-runbook.md)
- Benchmark execution: [docs/runbooks/benchmark-runbook.md](docs/runbooks/benchmark-runbook.md)
- DCGM metrics references: [docs/runbooks/dcgm-prometheus-metrics-reference.md](docs/runbooks/dcgm-prometheus-metrics-reference.md)
- vLLM metrics references: [docs/runbooks/vllm-prometheus-metrics-reference.md](docs/runbooks/vllm-prometheus-metrics-reference.md)

### Day-2 Validation Commands

```bash
kubectl -n llm-serving get inferenceservice
kubectl -n llm-serving get pods -o wide
kubectl -n llm-serving get hpa
kubectl -n monitoring get servicemonitor
```

## 6. Benchmarking

### Harness

- Orchestrator: [load-testing/scripts/run-benchmark.sh](load-testing/scripts/run-benchmark.sh)
- Load generator: [load-testing/scripts/python/loadgen.py](load-testing/scripts/python/loadgen.py)
- Metrics collector: [load-testing/scripts/python/metrics.py](load-testing/scripts/python/metrics.py)
- Statistics processor: [load-testing/scripts/python/statistic.py](load-testing/scripts/python/statistic.py)
- Profile configs: [load-testing/scripts/configs/](load-testing/scripts/configs)

### Artifacts

- Benchmark artifacts are generated locally and are not committed to Git.
- The output directory [load-testing/results/](load-testing/results) is excluded by [.gitignore](.gitignore#L44).
- Running [load-testing/scripts/run-benchmark.sh](load-testing/scripts/run-benchmark.sh) generates local files such as `benchmark-summary.csv`, `latency-vs-concurrency.csv`, `throughput-vs-concurrency.csv`, and request-level JSON logs under `load-testing/results/request-level/`.
- **Detailed report:** [docs/benchmarks/vllm-benchmark-report.md](docs/benchmarks/vllm-benchmark-report.md)

### Reported Outcome Snapshot

- Stable successful runs across tested concurrency tiers
- Throughput and latency trends are captured in CSV outputs
- Request-level evidence is available for replay and deeper analysis

## 7. Observability And Dashboards

### Metrics Stack

- GPU alerting rules: [kubernetes/base/monitoring/gpu-alert-rules.yaml](kubernetes/base/monitoring/gpu-alert-rules.yaml)
- GPU recording rules: [kubernetes/base/monitoring/gpu-recording-rules.yaml](kubernetes/base/monitoring/gpu-recording-rules.yaml)
- KServe ServiceMonitor: [kubernetes/serving/kserve/auto/phi-chat-servicemonitor.yaml](kubernetes/serving/kserve/auto/phi-chat-servicemonitor.yaml)
- vLLM ServiceMonitor: [kubernetes/serving/vllm/tinyllama-servicemonitor.yaml](kubernetes/serving/vllm/tinyllama-servicemonitor.yaml)

### Dashboard Evidence

- Dashboard screenshots: [docs/dashboards/](docs/dashboards)
- Grafana JSON definitions: [terraform/modules/observability/grafana/](terraform/modules/observability/grafana)

## 8. Known Limitations And Decisions

- The current implementation emphasizes a validated dev path first.
- Serving includes both a KServe-first and manual validation flow.
- Autoscaling decisions and trade-offs are documented in [docs/architecture/autoscaling-decision-record.md](docs/architecture/autoscaling-decision-record.md).
- Progressive hardening checklist is tracked in [docs/runbooks/vllm-battle-hardening-progressive-runbook.md](docs/runbooks/vllm-battle-hardening-progressive-runbook.md).


## 9. License

This project is licensed under MIT.

- License file: [LICENSE](LICENSE)

## 10. Connect with me on [Linkedin](https://www.linkedin.com/in/kelvin-onuchukwu-3460871a1/)