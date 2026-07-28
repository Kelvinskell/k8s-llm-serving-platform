resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = var.karpenter_gpu_nodeclass_name
      labels = {
        "app.kubernetes.io/part-of" = "llm-serving"
      }
    }
    spec = {
      amiFamily = "AL2023"
      role      = var.karpenter_node_role_name

      amiSelectorTerms = [
        {
          alias = "al2023@latest"
        }
      ]

      subnetSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]

      securityGroupSelectorTerms = [
        {
          tags = {
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
      ]

      tags = {
        "karpenter.sh/discovery" = var.cluster_name
        "Workload"               = "inference"
        "Environment"            = var.environment
        "ManagedBy"              = "Terraform"
      }

      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "200Gi"
            volumeType          = "gp3"
            iops                = 3000
            throughput          = 125
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]
    }
  })

  depends_on = [
    helm_release.karpenter_crd,
    helm_release.karpenter
  ]
}