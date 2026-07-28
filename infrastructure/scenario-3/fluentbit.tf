resource "kubernetes_namespace" "amazon_cloudwatch" {
  metadata {
    name = "amazon-cloudwatch"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  namespace  = kubernetes_namespace.amazon_cloudwatch.metadata[0].name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = var.fluentbit_chart_version
  timeout    = 900
  atomic     = true

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "fluentbit"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.fluentbit_irsa.iam_role_arn
        }
      }

      cloudWatchLogs = {
        enabled         = true
        region          = var.aws_region
        logGroupName    = "/eks/ms-learning"
        autoCreateGroup = true
        logStreamPrefix = "pod/"
      }

      firehose      = { enabled = false }
      kinesis       = { enabled = false }
      elasticsearch = { enabled = false }

      resources = {
        requests = { cpu = "50m", memory = "100Mi" }
        limits   = { cpu = "100m", memory = "200Mi" }
      }
    })
  ]

  depends_on = [module.eks]
}
