#!/bin/bash
# =============================================================================
# okd-approve-csr.sh — Approbation automatique des CSRs kubelet après reboot
# =============================================================================
# À exécuter à chaque démarrage du cluster OKD SNO
# Les certificats kubelet expirent ~24h si le cluster est éteint
#
# Usage: ./scripts/okd-approve-csr.sh
# =============================================================================

export KUBECONFIG=~/work/okd-sno-install/auth/kubeconfig

echo "[1/3] Attente API server..."
until oc get nodes &>/dev/null; do
  echo "  ... API server pas encore prêt, retry dans 5s"
  sleep 5
done

echo "[2/3] Approbation des CSRs pending..."
for i in {1..5}; do
  APPROVED=$(oc get csr -o name | xargs oc adm certificate approve 2>/dev/null | wc -l)
  echo "  Itération $i — $APPROVED CSRs approuvés"
  sleep 10
done

echo "[3/3] Redémarrage kubelet pour prise en compte..."
ssh -i ~/.ssh/okd-sno core@192.168.241.10 "sudo systemctl restart kubelet"

echo ""
echo "✅ Done — attendre ~2 min que les pods redémarrent"
echo "   oc get pods --all-namespaces | grep -v Running | grep -v Completed"
