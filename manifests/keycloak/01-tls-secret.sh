#!/bin/bash
# =============================================================================
# 01-tls-secret.sh — Copie le wildcard cert OKD dans le namespace keycloak
# =============================================================================
# À exécuter après chaque reboot ou si le secret keycloak-tls-secret est perdu
# Utilise le cert wildcard *.apps.sno.okd.lab géré par OKD ingress operator
# =============================================================================

export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

echo "Copie du wildcard cert OKD → namespace keycloak..."

oc get secret router-certs-default -n openshift-ingress -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences) \
    | .metadata.name = "keycloak-tls-secret" \
    | .metadata.namespace = "keycloak"' | \
  oc apply -f -

echo "✅ keycloak-tls-secret créé dans le namespace keycloak"
