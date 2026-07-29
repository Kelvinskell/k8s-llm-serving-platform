# Node group outputs for downstream environment wiring.
output "node_role_arn" {
  description = "IAM role ARN used by the managed node groups."
  value       = aws_iam_role.eks_node_role.arn
}

output "node_role_name" {
  description = "IAM role name used by the managed node groups."
  value       = aws_iam_role.eks_node_role.name
}

output "cpu_node_group_name" {
  description = "Name of the CPU managed node group."
  value       = aws_eks_node_group.cpu.node_group_name
}

output "gpu_node_group_name" {
  description = "Name of the GPU managed node group."
  value       = aws_eks_node_group.gpu.node_group_name
}