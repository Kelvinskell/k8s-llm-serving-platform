locals {
  # Split multi-doc YAML into deterministic, index-addressable documents.
  knative_serving_crds_docs = [
    for d in split("\n---\n", data.http.knative_serving_crds.response_body) :
    trimspace(d) if trimspace(d) != ""
  ]

  knative_serving_core_docs = [
    for d in split("\n---\n", data.http.knative_serving_core.response_body) :
    trimspace(d) if trimspace(d) != ""
  ]

  knative_net_istio_docs = [
    for d in split("\n---\n", data.http.knative_net_istio.response_body) :
    trimspace(d) if trimspace(d) != ""
  ]

  kserve_all_docs = [
    for d in split("\n---\n", data.http.kserve_all.response_body) :
    trimspace(d) if trimspace(d) != ""
  ]

  knative_serving_crds_manifest_map = {
    for idx, doc in local.knative_serving_crds_docs :
    tostring(idx) => doc
  }

  knative_serving_core_manifest_map = {
    for idx, doc in local.knative_serving_core_docs :
    tostring(idx) => doc
  }

  knative_net_istio_manifest_map = {
    for idx, doc in local.knative_net_istio_docs :
    tostring(idx) => doc
  }

  kserve_crd_manifest_map = {
    for idx, doc in local.kserve_all_docs :
    tostring(idx) => doc if can(regex("(?m)^kind:\\s*CustomResourceDefinition\\s*$", doc))
  }

  kserve_non_crd_manifest_map = {
    for idx, doc in local.kserve_all_docs :
    tostring(idx) => doc if !can(regex("(?m)^kind:\\s*CustomResourceDefinition\\s*$", doc))
  }
}