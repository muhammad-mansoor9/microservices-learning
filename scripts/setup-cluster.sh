#!/usr/bin/env bash
# All post-`terraform apply` cluster state is now Terraform-managed:
#   - Istio namespace label + PeerAuthentication + DestinationRules
#     (infrastructure/scenario-3/istio_policies.tf)
#   - ArgoCD Applications
#     (infrastructure/scenario-3/argocd_apps.tf)
#   - FluentBit DaemonSet via helm chart
#     (infrastructure/scenario-3/fluentbit.tf)
#
# This script now only does the two things Terraform can't do for you:
#   1. Update the local kubeconfig so `kubectl` targets the new cluster.
#   2. Sanity-check that the cluster is reachable.
#
# Everything else — Helm releases, IRSA roles, DBs, mesh policy, GitOps
# apps — happens on `terraform apply`.

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-ms-learning-eks}
AWS_REGION=${AWS_REGION:-us-east-1}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Updating kubeconfig for cluster ${CLUSTER_NAME} in ${AWS_REGION}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "Sanity check: cluster reachable, nodes are Ready"
kubectl get nodes

log "Sanity check: platform pods"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true

echo
echo "Kubeconfig set. Everything else is Terraform-managed —"
echo "run \`terraform apply\` in infrastructure/scenario-3/ to make changes."
