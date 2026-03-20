#!/bin/bash
# apply-kyverno-policies.sh — Apply Kyverno policies directly
set -e
export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

echo "→ Applying Kyverno policies..."
oc apply -f manifests/kyverno-policies/
echo "✅ Policies applied!"
oc get clusterpolicy
