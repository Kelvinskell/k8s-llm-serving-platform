output "vpc_id" {
  description = "VPC ID for the dev environment."
  value       = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the dev environment."
  value       = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the dev environment."
  value       = module.networking.private_subnet_ids
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs for the dev environment."
  value       = module.networking.nat_gateway_ids
}

# EKS cluster outputs
output "eks_cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_oidc_issuer_url" {
  description = "EKS cluster OIDC issuer URL."
  value       = module.eks.cluster_oidc_issuer_url
}

output "cpu_node_group_name" {
  description = "CPU node group name."
  value       = module.nodegroups.cpu_node_group_name
}

output "gpu_node_group_name" {
  description = "GPU node group name."
  value       = module.nodegroups.gpu_node_group_name
}

# Observability outputs
output "observability_release_name" {
  description = "kube-prometheus-stack Helm release name."
  value       = module.observability.release_name
}

output "observability_namespace" {
  description = "Namespace where kube-prometheus-stack is installed."
  value       = module.observability.namespace
}

output "kserve_version" {
  description = "Pinned KServe version configured by Terraform module."
  value       = module.kserve[0].kserve_version
}