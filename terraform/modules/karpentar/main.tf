# Install Karpentar Controller
resource "helm_release" "karpenter_crd" {
  name             = "${var.karpenter_release_name}-crd"
  repository       = var.karpenter_repository
  chart            = "${var.karpenter_chart_name}-crd"
  version          = var.karpenter_chart_version
  namespace        = var.karpenter_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds
}

# Install Karpentar 
resource "helm_release" "karpenter" {
  name             = var.karpenter_release_name
  repository       = var.karpenter_repository
  chart            = var.karpenter_chart_name
  version          = var.karpenter_chart_version
  namespace        = var.karpenter_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
      }
      serviceAccount = {
        create = true
        name   = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
        }
      }
    })
  ]
  depends_on = [
    helm_release.karpenter_crd,
    aws_iam_role_policy_attachment.karpenter_controller
  ]
}