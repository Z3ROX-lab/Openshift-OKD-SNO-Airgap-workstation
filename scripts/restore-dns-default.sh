#!/bin/bash
# =============================================================================
# restore-dns-default.sh — Remet la config DNS WSL2 par défaut
# =============================================================================
# Ce script :
#   1. Arrête dnsmasq
#   2. Supprime la config OKD de dnsmasq
#   3. Réactive systemd-resolved
#   4. Réactive la génération automatique de resolv.conf par WSL2
#
# Pour réactiver OKD DNS : ./setup-dns-okd.sh
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[RESTORE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo "============================================="
echo "  Restauration DNS WSL2 par défaut"
echo "============================================="
echo ""

# -----------------------------------------------------------------------------
# 1. Arrêter et désactiver dnsmasq
# -----------------------------------------------------------------------------
log "Arrêt de dnsmasq..."
sudo systemctl stop dnsmasq 2>/dev/null || true
sudo systemctl disable dnsmasq 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. Supprimer la config OKD
# -----------------------------------------------------------------------------
if [ -f /etc/dnsmasq.d/okd-sno.conf ]; then
    log "Suppression de /etc/dnsmasq.d/okd-sno.conf..."
    sudo rm -f /etc/dnsmasq.d/okd-sno.conf
else
    log "Config OKD dnsmasq déjà absente ✓"
fi

# -----------------------------------------------------------------------------
# 3. Réactiver systemd-resolved
# -----------------------------------------------------------------------------
log "Réactivation de systemd-resolved..."
sudo systemctl enable systemd-resolved 2>/dev/null || true
sudo systemctl start systemd-resolved 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Réactiver la gestion automatique resolv.conf par WSL2
# -----------------------------------------------------------------------------
log "Restauration de /etc/wsl.conf..."
sudo tee /etc/wsl.conf > /dev/null << EOF
[network]
generateResolvConf = true
EOF

log "Suppression du resolv.conf manuel..."
sudo rm -f /etc/resolv.conf

# Recréer le lien symlink standard Ubuntu/WSL2
sudo ln -sf /run/resolvconf/resolv.conf /etc/resolv.conf 2>/dev/null || \
sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || \
warn "Impossible de recréer le symlink — redémarre WSL2 : 'wsl --shutdown' depuis PowerShell"

# -----------------------------------------------------------------------------
# 5. Validation
# -----------------------------------------------------------------------------
echo ""
log "Validation..."
sleep 1

INET=$(dig github.com +short 2>/dev/null | head -1)
if [ -n "$INET" ]; then
    log "github.com → ${INET} ✅ (Internet OK)"
else
    warn "github.com non résolu — un redémarrage WSL2 peut être nécessaire"
    warn "Depuis PowerShell Windows : wsl --shutdown"
fi

echo ""
echo "============================================="
echo "  DNS WSL2 restauré par défaut !"
echo "  Pour réactiver OKD DNS : ./setup-dns-okd.sh"
echo "============================================="
echo ""
