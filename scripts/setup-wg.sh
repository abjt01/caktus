#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Phase 2: WireGuard Key Generation & Config Generator
# Run on the LAPTOP. Also generates VPS config template.
#
# Usage: bash ~/caktus/scripts/setup-wg.sh
# ─────────────────────────────────────────────────────────────────────
set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BOLD}[→]${NC} $1"; }

echo ""
echo "🌵 WireGuard Setup — Project Caktus"
echo "════════════════════════════════════════"
echo ""

# ─── Check WireGuard is installed ────────────────────────────────────
if ! command -v wg &>/dev/null; then
    echo -e "${RED}[✗]${NC} WireGuard not found. Run setup-laptop.sh first."
    exit 1
fi

# ─── Generate laptop keys ─────────────────────────────────────────────
info "Generating WireGuard key pair for this laptop..."
LAPTOP_PRIVATE=$(wg genkey)
LAPTOP_PUBLIC=$(echo "$LAPTOP_PRIVATE" | wg pubkey)
log "Laptop key pair generated"

# ─── Write laptop private key securely ───────────────────────────────
sudo bash -c "echo '$LAPTOP_PRIVATE' > /etc/wireguard/laptop_private.key"
sudo bash -c "echo '$LAPTOP_PUBLIC'  > /etc/wireguard/laptop_public.key"
sudo chmod 600 /etc/wireguard/laptop_private.key
sudo chmod 644 /etc/wireguard/laptop_public.key
log "Keys saved to /etc/wireguard/"

# ─── Prompt for VPS public key ───────────────────────────────────────
echo ""
warn "You need the VPS public key. On the VPS, run:"
echo -e "${CYAN}"
cat << 'EOF'
  sudo apt update && sudo apt install -y wireguard
  wg genkey | sudo tee /etc/wireguard/vps_private.key | \
    wg pubkey | sudo tee /etc/wireguard/vps_public.key
  sudo chmod 600 /etc/wireguard/vps_private.key
  cat /etc/wireguard/vps_public.key
EOF
echo -e "${NC}"
echo -n "Paste the VPS PUBLIC key here: "
read -r VPS_PUBLIC_KEY

if [ -z "$VPS_PUBLIC_KEY" ]; then
    warn "No VPS public key entered. You can edit wg0.conf manually later."
    VPS_PUBLIC_KEY="PASTE_VPS_PUBLIC_KEY_HERE"
fi

# ─── Prompt for VPS IP ───────────────────────────────────────────────
echo -n "Enter your VPS public IP address: "
read -r VPS_IP

if [ -z "$VPS_IP" ]; then
    warn "No VPS IP entered. Edit wg0.conf to add it."
    VPS_IP="YOUR_VPS_PUBLIC_IP"
fi

# ─── Write laptop wg0.conf ───────────────────────────────────────────
info "Writing /etc/wireguard/wg0.conf for laptop..."
sudo bash -c "cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.0.0.2/24
PrivateKey = ${LAPTOP_PRIVATE}
# DNS = 10.0.0.1  # Uncomment if you want DNS through VPS

[Peer]
# VPS (Oracle Cloud)
PublicKey = ${VPS_PUBLIC_KEY}
Endpoint = ${VPS_IP}:51820
AllowedIPs = 10.0.0.1/32
# Critical: prevents NAT table expiry through ISP router
PersistentKeepalive = 25
EOF"
sudo chmod 600 /etc/wireguard/wg0.conf
log "Laptop wg0.conf written"

# ─── Generate VPS config template ────────────────────────────────────
info "Generating VPS config template..."
cat > /tmp/vps_wg0.conf << EOF
[Interface]
Address = 10.0.0.1/24
ListenPort = 51820
PrivateKey = PASTE_VPS_PRIVATE_KEY_HERE

# Enable IP forwarding for traffic relay
# IMPORTANT: Replace VPS_IFACE below with your VPS network interface name.
# On Oracle Cloud it is usually: ens3  (run 'ip link show' on VPS to check)
# On older installs it may be: eth0, enp0s3, ens160
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT
PostUp   = iptables -A FORWARD -o wg0 -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -o VPS_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -D FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o VPS_IFACE -j MASQUERADE

[Peer]
# Laptop (Caktus Server)
PublicKey = ${LAPTOP_PUBLIC}
AllowedIPs = 10.0.0.2/32
EOF

warn "VPS_IFACE in /tmp/vps_wg0.conf is a placeholder."
warn "On VPS run 'ip link show' to find interface name, then replace VPS_IFACE."
log "VPS config template saved to /tmp/vps_wg0.conf"

# ─── Enable and start WireGuard ──────────────────────────────────────
echo ""
info "Enabling WireGuard service..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0 || warn "Could not start WireGuard yet — check VPS config first"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
log "WireGuard setup complete!"
echo ""
echo -e "  ${BOLD}Your laptop public key (give this to VPS peer config):${NC}"
echo -e "  ${CYAN}${LAPTOP_PUBLIC}${NC}"
echo ""
echo "  Copy /tmp/vps_wg0.conf to the VPS:"
echo "  scp /tmp/vps_wg0.conf ubuntu@${VPS_IP}:/tmp/"
echo ""
echo "  On VPS, run:"
echo "    sudo cp /tmp/vps_wg0.conf /etc/wireguard/wg0.conf"
echo "    sudo chmod 600 /etc/wireguard/wg0.conf"
echo "    sudo systemctl enable --now wg-quick@wg0"
echo ""
echo "  Then test tunnel from laptop:"
echo "    ping -c 4 10.0.0.1"
echo ""
