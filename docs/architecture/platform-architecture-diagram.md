# Platform Architecture Diagram

Use this Mermaid source directly in:
- Mermaid Live Editor
- Markdown preview with Mermaid support
- Draw.io Mermaid import

```mermaid
flowchart TB
  %% External
  client[Client Apps and Load Generator]
  alb[(AWS External LB\nALB/NLB - env specific)]

  %% AWS foundation
  subgraph aws[AWS Account]
    subgraph vpc[VPC]
      pub[Public Subnets]
      priv[Private Subnets]
      nat[NAT Gateway]
      igw[Internet Gateway]
    end

    subgraph eks[EKS Cluster]
      cp[EKS Control Plane]

      subgraph nodepool[Worker Capacity]
        cpu[CPU Node Group]
        gpu[GPU Node Group\nlabel: gpu=true\ntaint: nvidia.com/gpu]
        karp[Karpenter\nEC2NodeClass + NodePool]
      end

      subgraph platform[Platform Services]
        nvidia[NVIDIA Device Plugin\nGPU time slicing]
        cache[Model Cache Warmer DaemonSet\n/var/lib/llm-model-cache]
      end

      subgraph ingress[Ingress and Serving Control Plane]
        istio[Istio Ingress Gateway]
        knative[Knative net-istio]
        kserve[KServe Controller]
      end

      subgraph serving[Inference Namespace llm-serving]
        isvc[InferenceService\nphi-chat-2 and phi-chat-3]
        predictor[vLLM Predictor Pods\nRawDeployment]
      end

      subgraph autoscale[Autoscaling]
        hpa[KServe-managed HPA]
        keda[KEDA + ScaledObject\nPrometheus triggers]
      end

      subgraph observability[Observability]
        prom[Prometheus]
        graf[Grafana Dashboards]
        dcgm[DCGM Exporter]
        sm[ServiceMonitors - vLLM and KServe]
      end
    end
  end

  %% Network and infra relations
  igw --> pub
  pub --> nat
  nat --> priv
  cp --- priv
  cpu --- priv
  gpu --- priv

  %% Request path
  client --> alb --> istio --> knative --> isvc --> predictor

  %% Scheduling and runtime dependencies
  kserve --> isvc
  predictor --> gpu
  nvidia --> gpu
  cache --> predictor
  karp -. provisions when unschedulable .-> gpu

  %% Autoscaling relations
  prom --> hpa
  prom --> keda
  hpa --> predictor
  keda -. optional or alternate owner .-> predictor

  %% Metrics path
  predictor --> sm
  dcgm --> prom
  sm --> prom
  prom --> graf

  %% Styling
  classDef infra fill:#e8f1ff,stroke:#4a78c2,stroke-width:1px;
  classDef serving fill:#eaf9f0,stroke:#2d8a57,stroke-width:1px;
  classDef control fill:#fff3e8,stroke:#c97a2a,stroke-width:1px;
  classDef obs fill:#f3ecff,stroke:#7b57c2,stroke-width:1px;

  class vpc,pub,priv,nat,igw,cp,cpu,gpu,karp infra;
  class istio,knative,kserve,isvc,predictor,cache,nvidia,hpa,keda control;
  class prom,graf,dcgm,sm obs;
  class client,alb serving;
```

## Reading Guide
- Solid arrows show primary request/data/control flow.
- Dashed arrows show conditional behavior (for example Karpenter expansion or optional KEDA ownership).
