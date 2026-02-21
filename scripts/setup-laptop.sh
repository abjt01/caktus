#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Laptop Setup Script — Project Caktus
# Run once on your Ubuntu laptop.
# Sets up: Docker, no-sleep, UFW, project structure.
#
# Usage: bash scripts/setup-laptop.sh
# ─────────────────────────────────────────────────────────────────────
set -e

CAKTUS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
sudo apt install -y curl git ufw htop net-tools dnsutils
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
    log "Docker installed. NOTE: Log out and back in for group changes."
fi

sudo docker compose version || fail "docker compose plugin not found"
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
sudo ufw --force enable
sudo ufw status verbose
log "Firewall configured"

# ─── Step 5: Project Structure ───────────────────────────────────────
info "Step 5: Creating project directories..."
mkdir -p "$CAKTUS_DIR"/{caddy,apps,scripts,docs}
log "Project directories ready at $CAKTUS_DIR"

# ─── Step 6: .env Setup ─────────────────────────────────────────────
info "Step 6: Checking .env..."
if [ -f "$CAKTUS_DIR/.env" ]; then
    warn ".env already exists — skipping"
else
    if [ -f "$CAKTUS_DIR/.env.example" ]; then
        cp "$CAKTUS_DIR/.env.example" "$CAKTUS_DIR/.env"
        log "Created .env from .env.example — fill in your ngrok credentials"
    else
        warn ".env.example not found — create .env manually"
    fi
fi

echo ""
echo "════════════════════════════════════════"
log "Laptop setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Sign up at ngrok.com (free)"
echo "  2. Fill in .env with your NGROK_AUTHTOKEN and NGROK_DOMAIN"
echo "  3. Run: docker compose up -d"
echo "  4. Open http://localhost to see your landing page"
echo ""
