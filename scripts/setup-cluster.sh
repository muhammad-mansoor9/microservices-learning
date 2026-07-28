#!/usr/bin/env bash
# Bootstrap the EKS cluster for Scenario 3: kubeconfig, Istio, mTLS
# policy, and ArgoCD Applications.
#
# Idempotent — safe to re-run. Uses `helm upgrade --install` and
# `kubectl apply` so a partially-run script leaves nothing behind.
#
# Prerequisites:
#   - Terraform stack in infrastructure/scenario-3/ already applied
#     (creates the cluster, ArgoCD, and the Istio Helm releases).
#     Running this script when Terraform already installed Istio is
#     fine — `helm upgrade --install` is a no-op if the release is
#     current.
#   - aws, kubectl, helm on PATH.

set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-ms-learning-eks}
AWS_REGION=${AWS_REGION:-us-east-1}
ISTIO_VERSION=${ISTIO_VERSION:-1.23.0}
ISTIO_REPO_URL=${ISTIO_REPO_URL:-https://istio-release.storage.googleapis.com/charts}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Updating kubeconfig for cluster ${CLUSTER_NAME} in ${AWS_REGION}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "Adding Istio Helm repo"
helm repo add istio "${ISTIO_REPO_URL}" >/dev/null 2>&1 || true
helm repo update istio >/dev/null

log "Ensuring istio-system namespace exists"
kubectl get namespace istio-system >/dev/null 2>&1 \
  || kubectl create namespace istio-system

log "Installing/upgrading istio-base ${ISTIO_VERSION}"
helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --version "${ISTIO_VERSION}"

log "Installing/upgrading istiod ${ISTIO_VERSION}"
helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --version "${ISTIO_VERSION}" \
  --wait

# Istio ingress gateway install intentionally skipped — AWS LB Controller
# handles external traffic. Uncomment to enable once the gateway pod's
# readiness stall is understood.
# log "Installing/upgrading istio-ingress ${ISTIO_VERSION} (ClusterIP)"
# helm upgrade --install istio-ingress istio/gateway \
#   --namespace istio-system \
#   --version "${ISTIO_VERSION}" \
#   --set service.type=ClusterIP

log "Labelling default namespace for sidecar injection"
kubectl apply -f "${REPO_ROOT}/k8s/namespace.yaml"

log "Applying mesh policies (PeerAuthentication + DestinationRules)"
kubectl apply -f "${REPO_ROOT}/k8s/istio/peer-authentication.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/istio/destination-rules.yaml"

log "Applying ArgoCD Application manifests"
kubectl apply -f "${REPO_ROOT}/argocd/order-service-app.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/payment-service-app.yaml"
kubectl apply -f "${REPO_ROOT}/argocd/user-service-app.yaml"

echo
echo "Cluster setup complete — ArgoCD will now sync deployments"
