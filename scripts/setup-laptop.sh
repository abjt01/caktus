#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Phase 0 + 4: Laptop Setup Script
# Run once on your Ubuntu 22.04 laptop.
# Sets up: deps, Docker, static IP prompt, UFW firewall,
#           no-sleep settings, and project structure.
#
# Usage: bash ~/caktus/scripts/setup-laptop.sh
# ─────────────────────────────────────────────────────────────────────
set -e

CAKTUS_DIR="$HOME/caktus"
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BOLD}[→]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo "🌵 Project Caktus — Laptop Setup"
echo "════════════════════════════════════════"
echo ""

# ─── Step 1: System Update ───────────────────────────────────────────
info "Step 1: Updating system packages..."
sudo apt update -qq && sudo apt upgrade -y -qq
sudo apt install -y curl git ufw htop net-tools wireguard dnsutils
log "System packages installed"

# ─── Step 2: Docker ──────────────────────────────────────────────────
info "Step 2: Installing Docker Engine..."
if command -v docker &>/dev/null; then
    warn "Docker already installed: $(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    sudo apt install -y docker-compose-plugin
    sudo systemctl enable docker
    log "Docker installed. NOTE: Log out and back in for group changes to take effect."
fi

# docker group takes effect on next login — use sudo for this check
sudo docker compose version || fail "docker compose plugin not found — install it manually"
log "Docker Compose v2 confirmed"

# ─── Step 3: Prevent Laptop Sleep ────────────────────────────────────
info "Step 3: Disabling sleep/suspend..."
sudo sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' \
    /etc/systemd/logind.conf
sudo sed -i 's/HandleLidSwitch=suspend/HandleLidSwitch=ignore/' \
    /etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' \
    /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
log "Laptop will stay awake with lid closed"

# ─── Step 4: UFW Firewall ────────────────────────────────────────────
info "Step 4: Configuring UFW firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 51820/udp
sudo ufw --force enable
sudo ufw status verbose
log "Firewall configured"

# ─── Step 5: SSH Hardening ───────────────────────────────────────────
info "Step 5: Hardening SSH (keys only, no passwords)..."
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' \
    /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' \
    /etc/ssh/sshd_config
sudo systemctl restart sshd
log "SSH password auth disabled"

# ─── Step 6: Security Tools ──────────────────────────────────────────
info "Step 6: Installing fail2ban and unattended-upgrades..."
sudo apt install -y fail2ban unattended-upgrades
sudo systemctl enable --now fail2ban
sudo dpkg-reconfigure --priority=low unattended-upgrades
log "fail2ban active, auto security updates enabled"

# ─── Step 7: Docker Socket Permissions ───────────────────────────────
info "Step 7: Securing Docker socket..."
sudo chmod 660 /var/run/docker.sock
sudo chown root:docker /var/run/docker.sock
log "Docker socket permissions set to 660"

# ─── Step 8: Project Structure ───────────────────────────────────────
info "Step 8: Creating project directories..."
mkdir -p "$CAKTUS_DIR"/{caddy,apps,scripts,docs}
log "Project directories ready at $CAKTUS_DIR"

# ─── Step 9: Static IP Reminder ──────────────────────────────────────
echo ""
warn "MANUAL STEP REQUIRED: Static LAN IP"
echo ""
echo "  Current network interfaces:"
ip link show | grep -E '^[0-9]' | awk '{print "  -", $2}'
echo ""
echo "  Current IPs:"
ip addr show | grep 'inet ' | awk '{print "  -", $2, "on", $NF}'
echo ""
echo "  To set static IP, edit /etc/netplan/01-netcfg.yaml:"
cat << 'NETPLAN'
  network:
    version: 2
    renderer: networkd
    ethernets:
      enp3s0:                         # ← your interface name
        dhcp4: no
        addresses: [192.168.1.100/24] # ← your chosen static IP
        gateway4: 192.168.1.1         # ← your router gateway
        nameservers:
          addresses: [1.1.1.1, 8.8.8.8]
NETPLAN
echo ""
echo "  Then run: sudo netplan apply"
echo ""

echo ""
echo "════════════════════════════════════════"
log "Laptop setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Set static IP via netplan (see above)"
echo "  2. Run: bash scripts/setup-wg.sh  (WireGuard keys)"
echo "  3. Follow Phase 1-3 in the runbook (VPS + DuckDNS)"
echo "  4. Run: docker compose up -d"
echo ""
