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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_env_file "$@"
strip_env_file_args ARGS "$@"
set -- "${ARGS[@]+"${ARGS[@]}"}"

COMPOSE_FILE="$CAKTUS_DIR/docker-compose.yml"
NGINX_FILE="$CAKTUS_DIR/nginx/nginx.conf"

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

# ─── Step 2: Add routing to nginx.conf ───────────────────────────────
info "Step 2/3: Adding route to nginx.conf..."

NGINX_ENTRY="
    # ── ${APP_NAME} ───────────────────────────────────────────────────────────
    server {
        listen 80;
        server_name ${APP_NAME}.caktus.local;
        location / { proxy_pass http://caktus-${APP_NAME}:${APP_PORT}; }
    }"

# Insert before the ADD NEW APP ROUTES marker
python3 - "$NGINX_FILE" "$NGINX_ENTRY" << 'PYEOF'
import sys

nginx_file = sys.argv[1]
new_route = sys.argv[2]

with open(nginx_file, 'r') as f:
    content = f.read()

# Insert before the marker line
insert_before = '\n    # ── ADD NEW APP ROUTES ABOVE THIS LINE'
if insert_before in content:
    content = content.replace(insert_before, new_route + '\n' + insert_before, 1)
else:
    content += new_route

with open(nginx_file, 'w') as f:
    f.write(content)

print("  Inserted nginx server block")
PYEOF

log "Route added to nginx.conf"

# ─── Step 3: Apply ───────────────────────────────────────────────────
info "Step 3/3: Applying changes..."

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d "$APP_NAME"
sleep 2

# Restart nginx to pick up new config
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart nginx
log "nginx restarted with new routes"

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
