# Cert manager
resource "helm_release" "cert_manager" {
  name             = var.cert_manager_release_name
  repository       = var.cert_manager_repository
  chart            = var.cert_manager_chart
  version          = var.cert_manager_chart_version
  namespace        = var.cert_manager_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds

  set {
    name  = "crds.enabled"
    value = "true"
  }
}

# istio base
resource "helm_release" "istio_base" {
  name             = var.istio_base_release_name
  repository       = var.istio_repository
  chart            = "base"
  version          = var.istio_chart_version
  namespace        = var.istio_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds
}

# Istio daemon
resource "helm_release" "istiod" {
  name             = var.istiod_release_name
  repository       = var.istio_repository
  chart            = "istiod"
  version          = var.istio_chart_version
  namespace        = var.istio_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds

  depends_on = [helm_release.istio_base]
}

# Istio Ingress
resource "helm_release" "istio_ingressgateway" {
  name             = var.istio_ingressgateway_release_name
  repository       = var.istio_repository
  chart            = "gateway"
  version          = var.istio_chart_version
  namespace        = var.istio_namespace
  create_namespace = true

  wait            = true
  atomic          = true
  cleanup_on_fail = true
  timeout         = var.helm_timeout_seconds

  depends_on = [helm_release.istiod]
}

# KNative resources
resource "null_resource" "knative_serving_crds" {
  triggers = {
    version = var.knative_serving_version
  }

  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/knative/serving/releases/download/${var.knative_serving_version}/serving-crds.yaml"
  }

  depends_on = [helm_release.istio_ingressgateway]
}

resource "null_resource" "knative_serving_core" {
  triggers = {
    version = var.knative_serving_version
  }

  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/knative/serving/releases/download/${var.knative_serving_version}/serving-core.yaml"
  }

  depends_on = [null_resource.knative_serving_crds]
}

resource "null_resource" "knative_net_istio" {
  triggers = {
    version = var.knative_net_istio_version
  }

  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/knative-extensions/net-istio/releases/download/${var.knative_net_istio_version}/net-istio.yaml"
  }

  depends_on = [null_resource.knative_serving_core]
}

resource "null_resource" "knative_set_istio_ingress" {
  triggers = {
    ingress_class = var.knative_ingress_class
  }

  provisioner "local-exec" {
    command = "kubectl patch configmap/config-network -n knative-serving --type merge --patch '{\"data\":{\"ingress-class\":\"${var.knative_ingress_class}\"}}'"
  }

  depends_on = [null_resource.knative_net_istio]
}

resource "null_resource" "kserve_install" {
  triggers = {
    version = var.kserve_version
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<-EOT
      set -euo pipefail

      kubectl create namespace kserve --dry-run=client -o yaml | kubectl apply -f -

      kubectl apply --server-side --force-conflicts --validate=false \
        -f https://github.com/kserve/kserve/releases/download/${var.kserve_version}/kserve.yaml

      kubectl wait --for=condition=Established --timeout=300s \
        crd/inferenceservices.serving.kserve.io \
        crd/servingruntimes.serving.kserve.io \
        crd/clusterservingruntimes.serving.kserve.io

      kubectl apply --server-side --force-conflicts --validate=false \
        -f https://github.com/kserve/kserve/releases/download/${var.kserve_version}/kserve.yaml
    EOT
  }

  depends_on = [null_resource.knative_set_istio_ingress]
}