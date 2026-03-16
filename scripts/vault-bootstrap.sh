#!/bin/bash
# =============================================================================
# vault-bootstrap.sh — Configuration initiale de Vault après chaque reboot
# =============================================================================
# Usage : ./scripts/vault-bootstrap.sh
# Prérequis : oc login, vault-0 pod Running
# =============================================================================
set -e

VAULT_POD="vault-0"
VAULT_NS="vault"
VAULT_TOKEN="root"

echo "🔐 Bootstrap Vault..."

# Fonction helper
vault_exec() {
  oc exec -it ${VAULT_POD} -n ${VAULT_NS} -- \
    env VAULT_TOKEN=${VAULT_TOKEN} vault "$@"
}

# -----------------------------------------------------------------------------
# 1. Kubernetes Auth
# -----------------------------------------------------------------------------
echo "📋 Configuration Kubernetes auth..."
vault_exec auth enable kubernetes 2>/dev/null || echo "  → Déjà activé"
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

# -----------------------------------------------------------------------------
# 2. Secrets Engine KV v2
# -----------------------------------------------------------------------------
echo "🗄️  Activation KV v2..."
vault_exec secrets enable -path=secret kv-v2 2>/dev/null || echo "  → Déjà activé"

# -----------------------------------------------------------------------------
# 3. Policies
# -----------------------------------------------------------------------------
echo "📜 Création des policies..."

vault_exec policy write keycloak-policy - << 'POLICY'
path "secret/data/keycloak/*" {
  capabilities = ["read", "list"]
}
POLICY

vault_exec policy write argocd-policy - << 'POLICY'
path "secret/data/argocd/*" {
  capabilities = ["read", "list"]
}
POLICY

# -----------------------------------------------------------------------------
# 4. Roles Kubernetes
# -----------------------------------------------------------------------------
echo "👤 Création des roles..."

vault_exec write auth/kubernetes/role/keycloak \
  bound_service_account_names=keycloak \
  bound_service_account_namespaces=keycloak \
  policies=keycloak-policy \
  ttl=24h

vault_exec write auth/kubernetes/role/argocd \
  bound_service_account_names=argocd-argocd-server \
  bound_service_account_namespaces=openshift-operators \
  policies=argocd-policy \
  ttl=24h

# -----------------------------------------------------------------------------
# 5. Secrets de base
# -----------------------------------------------------------------------------
echo "🔑 Création des secrets de base..."

vault_exec kv put secret/keycloak/config \
  realm="okd" \
  client_id="openshift"

echo ""
echo "✅ Vault bootstrap terminé !"
echo "   UI    : https://vault.apps.sno.okd.lab"
echo "   Token : root"
