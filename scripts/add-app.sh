#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# add-app.sh — Automates adding a new app to Caktus
#
# Usage: bash scripts/add-app.sh <appname> <port> <image:tag>
#
# Examples:
#   bash scripts/add-app.sh notes 3000 nickel-notes:latest
#   bash scripts/add-app.sh api   8080 myapi:v2
#   bash scripts/add-app.sh demo  5000 ghcr.io/user/app:main
# ─────────────────────────────────────────────────────────────────────
set -e

# Resolve project root relative to this script
CAKTUS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$CAKTUS_DIR/docker-compose.yml"
CADDY_FILE="$CAKTUS_DIR/caddy/Caddyfile"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BOLD}[→]${NC} $1"; }

# ─── Validate inputs ─────────────────────────────────────────────────
APP_NAME="$1"
APP_PORT="$2"
APP_IMAGE="$3"

if [ -z "$APP_NAME" ] || [ -z "$APP_PORT" ] || [ -z "$APP_IMAGE" ]; then
    echo ""
    fail "Usage: add-app.sh <name> <port> <image:tag>"
fi

# Validate app name (alphanumeric + hyphens only)
if ! echo "$APP_NAME" | grep -qE '^[a-z0-9][a-z0-9-]*$'; then
    fail "App name must be lowercase alphanumeric with hyphens only (e.g. 'my-app')"
fi

# Validate port
if ! echo "$APP_PORT" | grep -qE '^[0-9]+$' || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
    fail "Port must be a number between 1 and 65535"
fi

# Check for duplicate
if grep -q "container_name: caktus-${APP_NAME}" "$COMPOSE_FILE" 2>/dev/null; then
    fail "App 'caktus-${APP_NAME}' already exists in docker-compose.yml"
fi

echo ""
echo "🌵 Adding app to Caktus"
echo "════════════════════════════════════════"
echo "  Name:   $APP_NAME"
echo "  Port:   $APP_PORT"
echo "  Image:  $APP_IMAGE"
echo "  Local:  http://${APP_NAME}.caktus.local"
echo ""

# ─── Step 1: Append to docker-compose.yml ────────────────────────────
info "Step 1/3: Adding service to docker-compose.yml..."

COMPOSE_ENTRY="
  # ── ${APP_NAME} ───────────────────────────────────────────────────────────
  ${APP_NAME}:
    image: ${APP_IMAGE}
    container_name: caktus-${APP_NAME}
    networks:
      - caktus-net
    restart: unless-stopped"

# Append service before the volumes block
python3 - "$COMPOSE_FILE" "$COMPOSE_ENTRY" << 'PYEOF'
import sys

compose_file = sys.argv[1]
new_service = sys.argv[2]

with open(compose_file, 'r') as f:
    content = f.read()

# Insert before 'volumes:' block
insert_before = '\nvolumes:'
if insert_before in content:
    content = content.replace(insert_before, new_service + '\n' + insert_before, 1)
else:
    content += new_service

with open(compose_file, 'w') as f:
    f.write(content)

print("  Inserted service block")
PYEOF

log "Service added to docker-compose.yml"

# ─── Step 2: Add routing to Caddyfile ────────────────────────────────
info "Step 2/3: Adding route to Caddyfile..."

CADDY_ENTRY="
    # ── ${APP_NAME} ───────────────────────────────────────────────────────────
    @${APP_NAME} host ${APP_NAME}.caktus.local
    handle @${APP_NAME} {
        reverse_proxy caktus-${APP_NAME}:${APP_PORT}
    }"

# Insert before the default "handle {" block
python3 - "$CADDY_FILE" "$CADDY_ENTRY" << 'PYEOF'
import sys

caddy_file = sys.argv[1]
new_route = sys.argv[2]

with open(caddy_file, 'r') as f:
    content = f.read()

# Insert before the catch-all 'handle {' block
insert_before = '\n    handle {'
if insert_before in content:
    content = content.replace(insert_before, new_route + '\n' + insert_before, 1)
else:
    content += new_route

with open(caddy_file, 'w') as f:
    f.write(content)

print("  Inserted Caddy route")
PYEOF

log "Route added to Caddyfile"

# ─── Step 3: Apply ───────────────────────────────────────────────────
info "Step 3/3: Applying changes..."
cd "$CAKTUS_DIR"

docker compose up -d "$APP_NAME"
sleep 2

# Restart Caddy to pick up new config (admin API is off)
docker compose restart caddy
log "Caddy restarted with new routes"

# ─── Done ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
log "App '${APP_NAME}' is live!"
echo ""
echo -e "  ${BOLD}Local:${NC} http://${APP_NAME}.caktus.local"
echo -e "  ${BOLD}Tip:${NC}   Add to /etc/hosts: 127.0.0.1 ${APP_NAME}.caktus.local"
echo ""
echo "  Useful commands:"
echo "  • Logs:    docker compose logs -f ${APP_NAME}"
echo "  • Status:  docker compose ps ${APP_NAME}"
echo "  • Restart: docker compose restart ${APP_NAME}"
echo ""
