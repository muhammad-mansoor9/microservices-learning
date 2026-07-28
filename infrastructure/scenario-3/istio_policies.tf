resource "kubernetes_labels" "default_ns_injection" {
  api_version = "v1"
  kind        = "Namespace"

  metadata {
    name = "default"
  }

  labels = {
    "istio-injection" = "enabled"
  }

  depends_on = [helm_release.istiod]
}

resource "kubectl_manifest" "istio_peer_authentication" {
  yaml_body         = file("${path.module}/../../k8s/istio/peer-authentication.yaml")
  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.istiod]
}

data "kubectl_path_documents" "istio_destination_rules" {
  pattern = "${path.module}/../../k8s/istio/destination-rules.yaml"
}

resource "kubectl_manifest" "istio_destination_rules" {
  for_each = toset(data.kubectl_path_documents.istio_destination_rules.documents)

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [helm_release.istiod]
}
