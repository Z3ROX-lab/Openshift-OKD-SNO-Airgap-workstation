#!/bin/bash
# =============================================================================
# vault-bootstrap.sh — Configuration initiale de Vault après chaque reboot
# =============================================================================
# Usage :
#   export KEYCLOAK_ADMIN_PASSWORD="mon-password"
#   export KEYCLOAK_CLIENT_SECRET="mon-secret"
#   ./scripts/vault-bootstrap.sh
#
# Sans export → valeurs CHANGEME (à remplacer manuellement dans l'UI Vault)
# =============================================================================
set -e

VAULT_POD="vault-0"
VAULT_NS="vault"
VAULT_TOKEN="root"

echo "🔐 Bootstrap Vault..."

vault_exec() {
  oc exec -i ${VAULT_POD} -n ${VAULT_NS} -- \
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
# 5. Secrets (valeurs via variables d'environnement)
# -----------------------------------------------------------------------------
echo "🔑 Création des secrets..."

vault_exec kv put secret/keycloak/config \
  realm="okd" \
  client_id="openshift"

vault_exec kv put secret/keycloak/admin \
  username="admin" \
  password="${KEYCLOAK_ADMIN_PASSWORD:-CHANGEME}"

vault_exec kv put secret/keycloak/client-secrets \
  openshift_client_secret="${KEYCLOAK_CLIENT_SECRET:-CHANGEME}"

vault_exec kv put secret/argocd/github \
  token="${ARGOCD_GITHUB_TOKEN:-CHANGEME}"

echo ""
echo "✅ Vault bootstrap terminé !"
echo "   UI    : https://vault.apps.sno.okd.lab"
echo "   Token : root"
echo ""
if grep -q "CHANGEME" <<< "${KEYCLOAK_ADMIN_PASSWORD}${KEYCLOAK_CLIENT_SECRET}${ARGOCD_GITHUB_TOKEN}"; then
  echo "⚠️  Certains secrets sont à valeur CHANGEME."
  echo "   Mets à jour les vraies valeurs dans l'UI Vault ou via :"
  echo "   export KEYCLOAK_ADMIN_PASSWORD=xxx && ./scripts/vault-bootstrap.sh"
fi
