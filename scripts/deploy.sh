#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# deploy.sh — Full-stack deploy entry point for Project Caktus
#
# Usage:
#   bash scripts/deploy.sh
#   bash scripts/deploy.sh --env-file ~/.secrets/caktus.env
#
# What it does:
#   1. Validates env vars (NGROK_AUTHTOKEN, NGROK_DOMAIN)
#   2. Starts / updates all containers via docker compose up -d
#   3. Waits for caktus-caddy and caktus-ngrok to be running
#   4. Prints the public URL
# ─────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_env_file "$@"

echo ""
echo "🌵 Project Caktus — Deploy"
echo "════════════════════════════════════════"
echo "  Env file: $ENV_FILE"
echo ""

# ─── Step 1: Validate required env vars ──────────────────────────────
info "Step 1/3: Validating environment..."

NGROK_AUTHTOKEN="$(grep "^NGROK_AUTHTOKEN=" "$ENV_FILE" | cut -d= -f2-)"
NGROK_DOMAIN="$(grep "^NGROK_DOMAIN=" "$ENV_FILE" | cut -d= -f2-)"

if [ -z "$NGROK_AUTHTOKEN" ] || [[ "$NGROK_AUTHTOKEN" == *"<"* ]]; then
    fail "NGROK_AUTHTOKEN is missing or still a placeholder in $ENV_FILE"
fi

if [ -z "$NGROK_DOMAIN" ] || [[ "$NGROK_DOMAIN" == *"<"* ]]; then
    fail "NGROK_DOMAIN is missing or still a placeholder in $ENV_FILE"
fi

log "Env vars validated"

# ─── Step 2: Start / update all containers ───────────────────────────
info "Step 2/3: Starting containers..."
docker compose --env-file "$ENV_FILE" -f "$CAKTUS_DIR/docker-compose.yml" up -d
log "Containers started"

# ─── Step 3: Wait for caddy + ngrok to be running ────────────────────
info "Step 3/3: Waiting for caddy and ngrok to be ready..."
TIMEOUT=30
ELAPSED=0
CADDY_STATUS="missing"
NGROK_STATUS="missing"

while [ $ELAPSED -lt $TIMEOUT ]; do
    CADDY_STATUS=$(docker inspect --format='{{.State.Status}}' caktus-caddy 2>/dev/null || echo "missing")
    NGROK_STATUS=$(docker inspect --format='{{.State.Status}}' caktus-ngrok 2>/dev/null || echo "missing")
    if [ "$CADDY_STATUS" = "running" ] && [ "$NGROK_STATUS" = "running" ]; then
        break
    fi
    sleep 2
    ELAPSED=$(( ELAPSED + 2 ))
done

if [ "$CADDY_STATUS" != "running" ]; then
    warn "caktus-caddy is not running yet (status: $CADDY_STATUS)"
fi
if [ "$NGROK_STATUS" != "running" ]; then
    warn "caktus-ngrok is not running yet (status: $NGROK_STATUS)"
fi
if [ "$CADDY_STATUS" = "running" ] && [ "$NGROK_STATUS" = "running" ]; then
    log "All core services running"
fi

echo ""
echo "════════════════════════════════════════"
log "Deploy complete!"
echo ""
echo -e "  ${BOLD}Public URL:${NC} https://${NGROK_DOMAIN}"
echo ""
echo "  Next steps:"
echo "  • Check health:  bash scripts/health-check.sh"
echo "  • View logs:     bash scripts/logs.sh status"
echo ""
