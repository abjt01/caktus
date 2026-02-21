#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Laptop Setup Script — Project Caktus
# Run once on your Ubuntu laptop.
# Sets up: Docker, no-sleep, UFW, fail2ban, unattended-upgrades,
#          project structure, and automatic daily backups.
#
# Usage: bash scripts/setup-laptop.sh
# ─────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

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
    log "Docker installed. NOTE: Log out and back in for group changes."
fi

sudo systemctl enable docker
sudo systemctl start docker
sudo docker compose version || fail "docker compose plugin not found"
log "Docker Compose v2 confirmed — enabled on boot"

# ─── Step 3: Docker socket permissions ───────────────────────────────
info "Step 3: Hardening Docker socket permissions..."
sudo chmod 660 /var/run/docker.sock 2>/dev/null || true
log "Docker socket set to 660"

# ─── Step 4: Prevent Laptop Sleep ────────────────────────────────────
info "Step 4: Disabling sleep/suspend..."
sudo sed -i 's/#HandleLidSwitch=suspend/HandleLidSwitch=ignore/' \
    /etc/systemd/logind.conf
sudo sed -i 's/HandleLidSwitch=suspend/HandleLidSwitch=ignore/' \
    /etc/systemd/logind.conf
sudo sed -i 's/#HandleSuspendKey=suspend/HandleSuspendKey=ignore/' \
    /etc/systemd/logind.conf
sudo systemctl restart systemd-logind
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
log "Laptop will stay awake with lid closed"

# ─── Step 5: UFW Firewall ────────────────────────────────────────────
info "Step 5: Configuring UFW firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw --force enable
sudo ufw status verbose
log "Firewall configured"

# ─── Step 6: Fail2ban ────────────────────────────────────────────────
info "Step 6: Installing fail2ban..."
if command -v fail2ban-client &>/dev/null; then
    warn "fail2ban already installed"
else
    sudo apt install -y fail2ban
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    log "fail2ban installed and enabled"
fi

# ─── Step 7: Unattended Security Upgrades ────────────────────────────
info "Step 7: Enabling unattended security upgrades..."
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
log "Unattended security upgrades enabled"

# ─── Step 8: SSH hardening check ─────────────────────────────────────
info "Step 8: Checking SSH hardening..."
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    log "SSH password auth already disabled"
else
    warn "SSH password auth is NOT disabled. Edit /etc/ssh/sshd_config:"
    warn "  PasswordAuthentication no"
    warn "  Then: sudo systemctl restart sshd"
fi

# ─── Step 9: Project Structure ───────────────────────────────────────
info "Step 9: Creating project directories..."
mkdir -p "$CAKTUS_DIR"/{caddy,apps,scripts,docs,logs,backups}
log "Project directories ready at $CAKTUS_DIR"

# ─── Step 10: .env Setup ─────────────────────────────────────────────
info "Step 10: Checking .env..."
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

# ─── Step 11: Automatic Daily Backups ────────────────────────────────
info "Step 11: Setting up daily backup cron job (3am)..."
CRON_JOB="0 3 * * * bash $CAKTUS_DIR/scripts/backup.sh >> $CAKTUS_DIR/logs/backup.log 2>&1"
# Only add if not already present
if crontab -l 2>/dev/null | grep -qF "$CAKTUS_DIR/scripts/backup.sh"; then
    warn "Backup cron job already exists — skipping"
else
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    log "Daily backup scheduled at 3am"
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
echo "  Security checklist:"
echo "  • Disable SSH password auth: PasswordAuthentication no in /etc/ssh/sshd_config"
echo "  • Verify fail2ban: sudo fail2ban-client status"
echo "  • Verify firewall: sudo ufw status"
echo ""
