#!/bin/bash
# =============================================================================
# restore-haproxy-default.sh — Arrête HAProxy OKD et remet la config par défaut
# =============================================================================
# Ce script :
#   1. Arrête et désactive HAProxy
#   2. Restaure la config HAProxy par défaut Ubuntu
#
# Pour réactiver : ./setup-haproxy-okd.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[RESTORE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "============================================="
echo "  Restauration HAProxy par défaut"
echo "============================================="
echo ""

# -----------------------------------------------------------------------------
# 1. Arrêter HAProxy
# -----------------------------------------------------------------------------
log "Arrêt de HAProxy..."
sudo systemctl stop haproxy 2>/dev/null || true
sudo systemctl disable haproxy 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Restaurer config par défaut
# -----------------------------------------------------------------------------
if [ -f /etc/haproxy/haproxy.cfg.dpkg-dist ]; then
    log "Restauration config HAProxy par défaut..."
    sudo cp /etc/haproxy/haproxy.cfg.dpkg-dist /etc/haproxy/haproxy.cfg
else
    log "Suppression config OKD..."
    sudo tee /etc/haproxy/haproxy.cfg > /dev/null << 'EOF'
# HAProxy default config — restored by restore-haproxy-default.sh
# Run setup-haproxy-okd.sh to reconfigure for OKD SNO

global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 2000
    daemon

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    timeout connect 5s
    timeout client  1m
    timeout server  1m
EOF
fi

# -----------------------------------------------------------------------------
# 3. Vérifier que les ports sont libérés
# -----------------------------------------------------------------------------
echo ""
log "Vérification des ports libérés..."
sleep 1

for port in 6443 22623 443 80; do
    if sudo ss -tulnp | grep -q ":${port}"; then
        warn "Port ${port} encore occupé — vérifier manuellement"
    else
        log "Port ${port} → libéré ✅"
    fi
done

echo ""
echo "============================================="
echo "  HAProxy arrêté."
echo "  Pour réactiver OKD : ./setup-haproxy-okd.sh"
echo "============================================="
echo ""
