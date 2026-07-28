resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  timeout    = 900
  atomic     = true

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.aws_lb_controller_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  timeout    = 900
  atomic     = true
}

resource "kubernetes_namespace" "keda" {
  metadata {
    name = "keda"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "keda" {
  name       = "keda"
  namespace  = kubernetes_namespace.keda.metadata[0].name
  repository = "https://kedacore.github.io/charts"
  chart      = "keda"
  version    = var.keda_chart_version
  timeout    = 900
  atomic     = true
}

# -----------------------------------------------------------------------------
# Istio service mesh — provides mTLS between pods. External north-south traffic
# still enters through the AWS Load Balancer Controller (ALB Ingress), so the
# Istio ingress gateway Service is ClusterIP-only to avoid an unused NLB.
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "istio_base" {
  name       = "istio-base"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = var.istio_chart_version
  timeout    = 900
  atomic     = true
}

resource "helm_release" "istiod" {
  name       = "istiod"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_chart_version
  wait       = true
  timeout    = 900
  atomic     = true

  depends_on = [helm_release.istio_base]
}

# Istio ingress gateway intentionally not installed via Terraform.
# External north-south traffic is handled by the AWS Load Balancer
# Controller (ALB Ingress), so the gateway is optional here. The chart
# was consistently hanging past the 15 min Helm timeout on this cluster
# — bring it back once we've isolated why the gateway pod stalls on
# readiness. To re-enable, uncomment this block and (optionally) the
# matching helm install in scripts/setup-cluster.sh.
#
# resource "helm_release" "istio_ingress" {
#   name       = "istio-ingress"
#   namespace  = kubernetes_namespace.istio_system.metadata[0].name
#   repository = "https://istio-release.storage.googleapis.com/charts"
#   chart      = "gateway"
#   version    = var.istio_chart_version
#   timeout    = 900
#   atomic     = true
#
#   set {
#     name  = "service.type"
#     value = "ClusterIP"
#   }
#
#   depends_on = [helm_release.istiod]
# }

# -----------------------------------------------------------------------------
# kube-prometheus-stack — Prometheus operator, Alertmanager, Grafana, and
# the node-exporter/kube-state-metrics scrape targets. Grafana persistence
# is off to keep the footprint small on the t3.medium nodes.
# -----------------------------------------------------------------------------
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  timeout    = 900
  atomic     = true

  set {
    name  = "grafana.enabled"
    value = "true"
  }

  set {
    name  = "grafana.persistence.enabled"
    value = "false"
  }

  # Discover PodMonitor / ServiceMonitor resources across all namespaces
  # regardless of Helm-injected label selectors, so services don't need
  # to know which release name Prometheus was installed under.
  set {
    name  = "prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
}
