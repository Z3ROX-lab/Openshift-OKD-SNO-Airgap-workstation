#!/bin/bash
# =============================================================================
# setup-dns-okd.sh — Configure dnsmasq pour OKD SNO Lab
# =============================================================================
# Ce script :
#   1. Fixe le MTU WSL2 (évite les erreurs TLS sur les gros downloads)
#   2. Désactive le DNS override Tailscale (accès distant Tailscale non affecté)
#   3. Installe dnsmasq si absent
#   4. Crée la config DNS pour *.okd.lab → 192.168.241.10
#   5. Désactive systemd-resolved (libère le port 53)
#   6. Configure dnsmasq avec upstream DNS (Tailscale + Google)
#   7. Configure resolv.conf pour pointer sur dnsmasq
#   8. Verrouille resolv.conf (chattr +i) contre toute réécriture
#
# Compatibilité Tailscale : le DNS Tailscale (100.100.100.100) est
# ajouté comme upstream — dnsmasq forward tout ce qui n'est pas
# *.okd.lab vers Tailscale puis 8.8.8.8 en fallback.
# L'accès distant SSH/RDP via Tailscale reste 100% fonctionnel.
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
sudo ip link set eth0 mtu 1280 2>/dev/null || warn "Interface eth0 non trouvée, MTU ignoré"
log "MTU → $(cat /sys/class/net/eth0/mtu 2>/dev/null || echo 'n/a')"

# -----------------------------------------------------------------------------
# 2. Désactiver le DNS override Tailscale
#    (la connectivité réseau Tailscale reste intacte)
# -----------------------------------------------------------------------------
if command -v tailscale &>/dev/null; then
    log "Désactivation du DNS override Tailscale..."
    tailscale set --accept-dns=false
    log "Tailscale accept-dns=false ✓ (accès distant SSH/RDP inchangé)"
else
    warn "tailscale non trouvé dans le PATH — étape ignorée"
fi

# -----------------------------------------------------------------------------
# 3. Installer dnsmasq si absent
# -----------------------------------------------------------------------------
if ! command -v dnsmasq &>/dev/null; then
    log "Installation de dnsmasq..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq dnsmasq
else
    log "dnsmasq déjà installé ✓"
fi

# -----------------------------------------------------------------------------
# 4. Désactiver systemd-resolved (libère le port 53)
# -----------------------------------------------------------------------------
if systemctl is-active --quiet systemd-resolved; then
    log "Désactivation de systemd-resolved..."
    sudo systemctl disable systemd-resolved
    sudo systemctl stop systemd-resolved
else
    log "systemd-resolved déjà inactif ✓"
fi

# -----------------------------------------------------------------------------
# 5. Créer la config dnsmasq OKD
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

# Upstream DNS — forward tout ce qui n'est pas *.okd.lab
# Tailscale DNS en priorité, Google en fallback
server=100.100.100.100
server=8.8.8.8
EOF

# -----------------------------------------------------------------------------
# 6. Démarrer dnsmasq
# -----------------------------------------------------------------------------
log "Démarrage de dnsmasq..."
sudo systemctl enable dnsmasq 2>/dev/null
sudo systemctl restart dnsmasq

# -----------------------------------------------------------------------------
# 7. Configurer resolv.conf
# -----------------------------------------------------------------------------
log "Configuration de /etc/wsl.conf..."
sudo tee /etc/wsl.conf > /dev/null << EOF
[network]
generateResolvConf = false
EOF

log "Configuration de /etc/resolv.conf..."
# Déverrouiller au cas où il serait déjà chattr +i d'une précédente exécution
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null << EOF
# OKD SNO Lab — DNS local
# Géré par setup-dns-okd.sh — NE PAS MODIFIER MANUELLEMENT
# Pour revenir au défaut : restore-dns-default.sh
# Tailscale DNS géré via upstream dnsmasq (server=100.100.100.100)
nameserver 127.0.0.1
nameserver 100.100.100.100
nameserver 8.8.8.8
EOF

# -----------------------------------------------------------------------------
# 8. Verrouiller resolv.conf contre toute réécriture (Tailscale, WSL2...)
# -----------------------------------------------------------------------------
log "Verrouillage de /etc/resolv.conf (chattr +i)..."
sudo chattr +i /etc/resolv.conf
log "resolv.conf verrouillé ✓"

# -----------------------------------------------------------------------------
# 9. Validation
# -----------------------------------------------------------------------------
echo ""
log "Validation DNS..."
sleep 1

API=$(dig api.sno.okd.lab @127.0.0.1 +short 2>/dev/null)
APPS=$(dig console-openshift-console.apps.sno.okd.lab @127.0.0.1 +short 2>/dev/null)
INET=$(dig github.com @127.0.0.1 +short 2>/dev/null | head -1)

if [ "$API" = "$SNO_IP" ]; then
    log "api.sno.okd.lab        → ${API} ✅"
else
    err "api.sno.okd.lab → ECHEC (obtenu: '${API}') — vérifier dnsmasq"
fi

if [ "$APPS" = "$SNO_IP" ]; then
    log "console.apps.sno.okd.lab → ${APPS} ✅"
else
    err "console.apps.sno.okd.lab → ECHEC"
fi

if [ -n "$INET" ]; then
    log "github.com             → ${INET} ✅ (Internet OK)"
else
    warn "github.com non résolu — vérifier la connectivité Internet"
fi

echo ""
echo "============================================="
echo "  DNS OKD configuré avec succès !"
echo "  resolv.conf verrouillé (chattr +i)"
echo "  Tailscale accès distant : non affecté"
echo "  Pour revenir au défaut : ./restore-dns-default.sh"
echo "============================================="
echo ""
