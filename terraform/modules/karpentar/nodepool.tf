resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.karpenter_gpu_nodepool_name
      labels = {
        "app.kubernetes.io/part-of" = "llm-serving"
      }
    }
    spec = {
      template = {
        metadata = {
          labels = {
            eks.amazonaws.com/nodegroup = "k8s-llm-serving-gpu-dev" # This label is added here for scheduling compatibility with Nodes from AWS managed nodegroups.
            workload = "inference"
            gpu      = "true"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = var.karpenter_gpu_nodeclass_name
          }

          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "true"
              effect = "NoSchedule"
            }
          ]

          requirements = [
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "kubernetes.io/os"
              operator = "In"
              values   = ["linux"]
            },
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["on-demand"]
            },
            {
              key      = "karpenter.k8s.aws/instance-family"
              operator = "In"
              values   = ["g4dn"]
            },
            {
              key      = "karpenter.k8s.aws/instance-size"
              operator = "In"
              values   = ["xlarge"]
            }
          ]

          expireAfter = "168h"
        }
      }

      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "5m"
      }

      limits = {
        cpu = "64"
      }
    }
  })

  depends_on = [
    kubectl_manifest.gpu_node_class
  ]
}