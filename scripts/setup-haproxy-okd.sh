#!/bin/bash
# =============================================================================
# setup-haproxy-okd.sh — Configure HAProxy comme LB externe pour OKD SNO
# =============================================================================
# Ce script :
#   1. Fixe le MTU WSL2
#   2. Installe HAProxy si absent
#   3. Déploie la config HAProxy pour les 4 ports OKD
#   4. Démarre HAProxy
#   5. Valide les ports en écoute
#
# Pour arrêter : ./restore-haproxy-default.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[HAPROXY]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SNO_IP="192.168.241.10"

echo ""
echo "============================================="
echo "  Setup HAProxy OKD SNO Lab"
echo "  LB externe WSL2 → ${SNO_IP}"
echo "============================================="
echo ""

# -----------------------------------------------------------------------------
# 1. Fix MTU WSL2
# -----------------------------------------------------------------------------
log "Fix MTU WSL2 (1280)..."
sudo ip link set eth0 mtu 1280

# -----------------------------------------------------------------------------
# 2. Installer HAProxy si absent
# -----------------------------------------------------------------------------
if ! command -v haproxy &>/dev/null; then
    log "Installation de HAProxy..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq haproxy
else
    log "HAProxy déjà installé ($(haproxy -v 2>&1 | head -1)) ✓"
fi

# -----------------------------------------------------------------------------
# 3. Déployer la config HAProxy
# -----------------------------------------------------------------------------
log "Déploiement de /etc/haproxy/haproxy.cfg..."
sudo tee /etc/haproxy/haproxy.cfg > /dev/null << EOF
#---------------------------------------------------------------------
# HAProxy — OKD SNO Lab
# Load Balancer externe WSL2 → VM okd-sno-master
# Généré par setup-haproxy-okd.sh
#---------------------------------------------------------------------

global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 2000
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  1m
    timeout server  1m

#---------------------------------------------------------------------
# Stats — http://localhost:9000/stats
#---------------------------------------------------------------------
frontend stats
    bind *:9000
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:okdlab
    stats show-legends
    stats show-node

#---------------------------------------------------------------------
# API Server — oc login, kubectl, ArgoCD
#---------------------------------------------------------------------
frontend okd-api
    bind *:6443
    default_backend okd-api-backend

backend okd-api-backend
    balance roundrobin
    option ssl-hello-chk
    server sno-master ${SNO_IP}:6443 check

#---------------------------------------------------------------------
# Machine Config Server — bootstrap uniquement
#---------------------------------------------------------------------
frontend okd-mcs
    bind *:22623
    default_backend okd-mcs-backend

backend okd-mcs-backend
    balance roundrobin
    server sno-master ${SNO_IP}:22623 check

#---------------------------------------------------------------------
# Ingress HTTPS — toutes les apps OKD
#---------------------------------------------------------------------
frontend okd-https
    bind *:443
    default_backend okd-https-backend

backend okd-https-backend
    balance roundrobin
    option ssl-hello-chk
    server sno-master ${SNO_IP}:443 check

#---------------------------------------------------------------------
# Ingress HTTP — redirect vers HTTPS
#---------------------------------------------------------------------
frontend okd-http
    bind *:80
    default_backend okd-http-backend

backend okd-http-backend
    balance roundrobin
    server sno-master ${SNO_IP}:80 check

EOF

# -----------------------------------------------------------------------------
# 4. Valider la config
# -----------------------------------------------------------------------------
log "Validation de la config HAProxy..."
sudo haproxy -c -f /etc/haproxy/haproxy.cfg || err "Config HAProxy invalide"
log "Config valide ✓"

# -----------------------------------------------------------------------------
# 5. Démarrer HAProxy
# -----------------------------------------------------------------------------
log "Démarrage de HAProxy..."
sudo systemctl enable haproxy 2>/dev/null
sudo systemctl restart haproxy

# -----------------------------------------------------------------------------
# 6. Validation
# -----------------------------------------------------------------------------
echo ""
log "Validation des ports en écoute..."
sleep 1

for port in 6443 22623 443 80 9000; do
    if sudo ss -tulnp | grep -q ":${port}"; then
        log "Port ${port} → en écoute ✅"
    else
        warn "Port ${port} → pas en écoute ⚠️"
    fi
done

echo ""
echo "============================================="
echo "  HAProxy configuré avec succès !"
echo ""
echo "  Stats : http://localhost:9000/stats"
echo "  Login : admin / okdlab"
echo ""
echo "  Les backends sont DOWN jusqu'au"
echo "  démarrage de la VM OKD — c'est normal."
echo ""
echo "  Pour arrêter : ./restore-haproxy-default.sh"
echo "============================================="
echo ""
