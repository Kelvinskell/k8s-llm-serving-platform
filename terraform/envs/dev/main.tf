# Create networking module
module "networking" {
  source = "../../modules/networking"

  name_prefix          = var.name_prefix
  cluster_name         = var.cluster_name
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  nat_gateway_mode     = var.nat_gateway_mode
  tags                 = var.tags
}

# Create EKS control plane
module "eks" {
  source = "../../modules/eks"

  name_prefix           = var.name_prefix
  cluster_name          = var.cluster_name
  environment           = var.environment
  kubernetes_version    = var.kubernetes_version
  vpc_id                = module.networking.vpc_id
  vpc_cidr              = var.vpc_cidr
  private_subnet_ids    = module.networking.private_subnet_ids
  endpoint_access_mode  = var.endpoint_access_mode
  authentication_mode   = var.authentication_mode
  access_principal_arns = var.access_principal_arns
  tags                  = var.tags
}

# Deploy Karpenter controller and node provisioning resources.
module "karpentar" {
  source = "../../modules/karpentar"

  cluster_name              = module.eks.cluster_name
  cluster_endpoint          = module.eks.cluster_endpoint
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  karpenter_node_role_arn   = module.nodegroups.node_role_arn
  karpenter_node_role_name  = module.nodegroups.node_role_name
  tags                      = var.tags

  depends_on = [
    module.eks,
    module.nodegroups
  ]
}

# Deploy EKS add-ons 
module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name              = module.eks.cluster_name
  cluster_version           = var.kubernetes_version
  cluster_oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
  cluster_oidc_provider_arn = module.eks.cluster_oidc_provider_arn
  tags                      = var.tags

}

# Create CPU and GPU worker node groups
module "nodegroups" {
  source = "../../modules/nodegroups"

  name_prefix        = var.name_prefix
  environment        = var.environment
  cluster_name       = module.eks.cluster_name
  subnet_ids         = module.networking.private_subnet_ids
  cpu_instance_types = var.cpu_instance_types
  gpu_instance_types = var.gpu_instance_types
  gpu_ami_type       = var.gpu_ami_type
  gpu_disk_size_gb   = var.gpu_disk_size_gb
  tags               = var.tags

}

# Deploy NVIDIA device plugin via Helm as a self-managed add-on.
module "nvidia_device_plugin" {
  source = "../../modules/nvidia-device-plugin"

  enabled               = var.enable_nvidia_device_plugin
  time_slicing_replicas = var.time_slicing_replicas

  depends_on = [
    module.eks,
    module.nodegroups
  ]
}

# Deploy kube-prometheus-stack and related components
module "observability" {
  source = "../../modules/observability"

  enabled                      = var.enable_observability
  namespace                    = var.observability_namespace
  chart_version                = var.kube_prometheus_stack_chart_version
  prometheus_retention         = var.prometheus_retention
  prometheus_storage_class     = var.prometheus_storage_class
  prometheus_storage_size      = var.prometheus_storage_size
  enable_metrics_server        = var.enable_metrics_server
  metrics_server_chart_version = var.metrics_server_chart_version
  enable_dcgm_exporter         = var.enable_dcgm_exporter
  dcgm_exporter_chart_version  = var.dcgm_exporter_chart_version

  depends_on = [
    module.eks,
    module.nodegroups,
    module.nvidia_device_plugin
  ]
}

# Deploy Kserve crds
module "kserve" {
  count  = var.enable_kserve_module ? 1 : 0
  source = "../../modules/kserve"
}