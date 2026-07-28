variable "helm_timeout_seconds" {
  description = "Timeout for Helm operations in seconds."
  type        = number
  default     = 900
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster endpoint."
  type        = string
}

variable "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for IRSA trust policies."
  type        = string
}

variable "cluster_oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA trust policies."
  type        = string
}

variable "tags" {
  description = "Common tags applied to IAM resources."
  type        = map(string)
  default     = {}
}

variable "karpenter_namespace" {
  description = "Namespace for Karpenter."
  type        = string
  default     = "karpenter"
}

variable "karpenter_release_name" {
  description = "Helm release name for Karpenter."
  type        = string
  default     = "karpenter"
}

variable "karpenter_repository" {
  description = "Karpenter Helm OCI repository."
  type        = string
  default     = "oci://public.ecr.aws/karpenter"
}

variable "karpenter_chart_name" {
  description = "Karpenter chart name."
  type        = string
  default     = "karpenter"
}

variable "karpenter_chart_version" {
  description = "Karpenter chart version."
  type        = string
  default     = "1.14.0"
}

variable "karpenter_node_role_arn" {
  description = "IAM role ARN for EC2 nodes launched by Karpenter."
  type        = string
}

variable "karpenter_node_role_name" {
  description = "IAM role Name for EC2 nodes launched by Karpenter."
  type        = string
}

variable "karpenter_gpu_nodeclass_name" {
  description = "EC2NodeClass name for GPU nodes."
  type        = string
  default     = "gpu-default"
}

variable "karpenter_gpu_nodepool_name" {
  description = "NodePool name for GPU inference nodes."
  type        = string
  default     = "gpu-inference"
}