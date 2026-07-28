locals {
  argocd_app_files = [
    "${path.module}/../../argocd/order-service-app.yaml",
    "${path.module}/../../argocd/payment-service-app.yaml",
    "${path.module}/../../argocd/user-service-app.yaml",
  ]
}

resource "kubectl_manifest" "argocd_app" {
  for_each = { for f in local.argocd_app_files : basename(f) => f }

  yaml_body         = file(each.value)
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false

  depends_on = [helm_release.argocd]
}
