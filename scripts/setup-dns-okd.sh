#!/bin/bash
# =============================================================================
# setup-dns-okd.sh — Configure dnsmasq pour OKD SNO Lab
# =============================================================================
# Ce script :
#   1. Fixe le MTU WSL2 (évite les erreurs TLS sur les gros downloads)
#   2. Installe dnsmasq si absent
#   3. Crée la config DNS pour *.okd.lab → 192.168.241.10
#   4. Désactive systemd-resolved (libère le port 53)
#   5. Configure resolv.conf pour pointer sur dnsmasq
#
# Pour revenir à la config par défaut : ./restore-dns-default.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OKD-DNS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

SNO_IP="192.168.241.10"

echo ""
echo "============================================="
echo "  Setup DNS OKD SNO Lab"
echo "  *.okd.lab → ${SNO_IP}"
echo "============================================="
echo ""

# -----------------------------------------------------------------------------
# 1. Fix MTU WSL2
# -----------------------------------------------------------------------------
log "Fix MTU WSL2 (1280)..."
sudo ip link set eth0 mtu 1280
log "MTU → $(cat /sys/class/net/eth0/mtu)"

# -----------------------------------------------------------------------------
# 2. Installer dnsmasq si absent
# -----------------------------------------------------------------------------
if ! command -v dnsmasq &>/dev/null; then
    log "Installation de dnsmasq..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq dnsmasq
else
    log "dnsmasq déjà installé ✓"
fi

# -----------------------------------------------------------------------------
# 3. Désactiver systemd-resolved (libère le port 53)
# -----------------------------------------------------------------------------
if systemctl is-active --quiet systemd-resolved; then
    log "Désactivation de systemd-resolved..."
    sudo systemctl disable systemd-resolved
    sudo systemctl stop systemd-resolved
else
    log "systemd-resolved déjà inactif ✓"
fi

# -----------------------------------------------------------------------------
# 4. Créer la config dnsmasq OKD
# -----------------------------------------------------------------------------
log "Création de /etc/dnsmasq.d/okd-sno.conf..."
sudo tee /etc/dnsmasq.d/okd-sno.conf > /dev/null << EOF
# OKD SNO Lab — résolution DNS locale
# Généré par setup-dns-okd.sh
# Pour désactiver : restore-dns-default.sh

address=/api.sno.okd.lab/${SNO_IP}
address=/api-int.sno.okd.lab/${SNO_IP}
address=/.apps.sno.okd.lab/${SNO_IP}

# Écouter uniquement sur loopback — évite conflit avec DNS interne WSL2
listen-address=127.0.0.1
bind-interfaces
EOF

# -----------------------------------------------------------------------------
# 5. Démarrer dnsmasq
# -----------------------------------------------------------------------------
log "Démarrage de dnsmasq..."
sudo systemctl enable dnsmasq 2>/dev/null
sudo systemctl restart dnsmasq

# -----------------------------------------------------------------------------
# 6. Configurer resolv.conf
# -----------------------------------------------------------------------------
log "Configuration de /etc/wsl.conf..."
sudo tee /etc/wsl.conf > /dev/null << EOF
[network]
generateResolvConf = false
EOF

log "Configuration de /etc/resolv.conf..."
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null << EOF
# OKD SNO Lab — DNS local
# Pour revenir au défaut : restore-dns-default.sh
nameserver 127.0.0.1
nameserver 8.8.8.8
EOF

# -----------------------------------------------------------------------------
# 7. Validation
# -----------------------------------------------------------------------------
echo ""
log "Validation DNS..."
sleep 1

API=$(dig api.sno.okd.lab @127.0.0.1 +short 2>/dev/null)
APPS=$(dig console-openshift-console.apps.sno.okd.lab @127.0.0.1 +short 2>/dev/null)
INET=$(dig github.com @127.0.0.1 +short 2>/dev/null | head -1)

if [ "$API" = "$SNO_IP" ]; then
    log "api.sno.okd.lab → ${API} ✅"
else
    err "api.sno.okd.lab → ECHEC (obtenu: ${API})"
fi

if [ "$APPS" = "$SNO_IP" ]; then
    log "console.apps.sno.okd.lab → ${APPS} ✅"
else
    err "console.apps.sno.okd.lab → ECHEC"
fi

if [ -n "$INET" ]; then
    log "github.com → ${INET} ✅ (Internet OK)"
else
    warn "github.com non résolu — vérifier la connectivité Internet"
fi

echo ""
echo "============================================="
echo "  DNS OKD configuré avec succès !"
echo "  Pour revenir au défaut : ./restore-dns-default.sh"
echo "============================================="
echo ""
