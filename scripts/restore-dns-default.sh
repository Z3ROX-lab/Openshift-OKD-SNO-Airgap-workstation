#!/bin/bash
# =============================================================================
# restore-dns-default.sh — Remet la config DNS WSL2 par défaut
# =============================================================================
# Ce script :
#   1. Déverrouille resolv.conf (chattr -i)
#   2. Arrête et désactive dnsmasq
#   3. Supprime la config OKD de dnsmasq
#   4. Réactive systemd-resolved
#   5. Réactive le DNS override Tailscale (MagicDNS)
#   6. Remet resolv.conf avec Tailscale DNS (100.100.100.100)
#   7. Réactive la génération automatique de resolv.conf par WSL2
#
# Note Tailscale : resolv.conf est remis avec 100.100.100.100 en priorité.
# Tailscale le réécrit de toute façon au prochain démarrage WSL2.
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
# 1. Déverrouiller resolv.conf (chattr -i)
#    Obligatoire avant toute modification du fichier
# -----------------------------------------------------------------------------
log "Déverrouillage de /etc/resolv.conf (chattr -i)..."
sudo chattr -i /etc/resolv.conf 2>/dev/null || true
log "resolv.conf déverrouillé ✓"

# -----------------------------------------------------------------------------
# 2. Arrêter et désactiver dnsmasq
# -----------------------------------------------------------------------------
log "Arrêt de dnsmasq..."
sudo systemctl stop dnsmasq 2>/dev/null || true
sudo systemctl disable dnsmasq 2>/dev/null || true
log "dnsmasq arrêté ✓"

# -----------------------------------------------------------------------------
# 3. Supprimer la config OKD dnsmasq
# -----------------------------------------------------------------------------
if [ -f /etc/dnsmasq.d/okd-sno.conf ]; then
    log "Suppression de /etc/dnsmasq.d/okd-sno.conf..."
    sudo rm -f /etc/dnsmasq.d/okd-sno.conf
else
    log "Config OKD dnsmasq déjà absente ✓"
fi

# -----------------------------------------------------------------------------
# 4. Réactiver systemd-resolved
# -----------------------------------------------------------------------------
log "Réactivation de systemd-resolved..."
sudo systemctl enable systemd-resolved 2>/dev/null || true
sudo systemctl start systemd-resolved 2>/dev/null || true
log "systemd-resolved actif ✓"

# -----------------------------------------------------------------------------
# 5. Réactiver le DNS override Tailscale (MagicDNS)
#    Permet à nouveau la résolution des hostnames Tailscale depuis WSL2
# -----------------------------------------------------------------------------
if command -v tailscale &>/dev/null; then
    log "Réactivation du DNS Tailscale (MagicDNS)..."
    tailscale set --accept-dns=true
    log "Tailscale accept-dns=true ✓"
else
    warn "tailscale non trouvé dans le PATH — étape ignorée"
    warn "Si Tailscale est installé, exécuter manuellement : tailscale set --accept-dns=true"
fi

# -----------------------------------------------------------------------------
# 6. Restaurer resolv.conf
# -----------------------------------------------------------------------------
log "Restauration de /etc/wsl.conf..."
sudo tee /etc/wsl.conf > /dev/null << EOF
[network]
generateResolvConf = true
EOF

log "Restauration de /etc/resolv.conf avec Tailscale DNS..."
sudo rm -f /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null << EOF
# DNS par défaut — Tailscale + Google
# Tailscale réécrit ce fichier au prochain redémarrage WSL2
nameserver 100.100.100.100
nameserver 8.8.8.8
EOF

# Pas de chattr +i ici — on laisse WSL2 et Tailscale gérer le fichier normalement

# -----------------------------------------------------------------------------
# 7. Validation
# -----------------------------------------------------------------------------
echo ""
log "Validation..."
sleep 1

INET=$(dig github.com +short 2>/dev/null | head -1)
if [ -n "$INET" ]; then
    log "github.com → ${INET} ✅ (Internet OK)"
else
    warn "github.com non résolu"
    warn "Un redémarrage WSL2 peut être nécessaire : wsl --shutdown (depuis PowerShell)"
fi

# Vérifier que les entrées OKD ne répondent plus
OKD=$(dig api.sno.okd.lab +short 2>/dev/null)
if [ -z "$OKD" ]; then
    log "api.sno.okd.lab → non résolu ✅ (OKD DNS bien désactivé)"
else
    warn "api.sno.okd.lab répond encore (${OKD}) — dnsmasq pas complètement arrêté ?"
fi

echo ""
echo "============================================="
echo "  DNS WSL2 restauré par défaut !"
echo "  Tailscale MagicDNS : réactivé"
echo "  Pour réactiver OKD DNS : ./setup-dns-okd.sh"
echo "============================================="
echo ""
