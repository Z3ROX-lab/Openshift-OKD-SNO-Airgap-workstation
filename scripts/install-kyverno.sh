#!/bin/bash
# install-kyverno.sh — Installation Kyverno v1.12.0 via Helm
# Note: Kyverno crée des ClusterRoles/CRDs → ne peut pas être géré
# par ArgoCD en mode namespaced. Helm direct utilisé à la place.
# En production : utiliser ArgoCD cluster mode.

set -e
export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

echo "→ Création namespace kyverno..."
oc create namespace kyverno 2>/dev/null || true
oc label namespace kyverno argocd.argoproj.io/managed-by=openshift-operators 2>/dev/null || true

echo "→ Installation Kyverno v1.12.0..."
helm upgrade --install kyverno kyverno/kyverno \
  --version 3.2.0 \
  --namespace kyverno \
  --create-namespace \
  -f manifests/kyverno/values.yaml

echo "→ Vérification pods..."
oc rollout status deployment/kyverno-admission-controller -n kyverno
echo "✅ Kyverno installé !"
