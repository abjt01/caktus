#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# remove-app.sh — Removes an app from Caktus
#
# Usage: bash scripts/remove-app.sh <appname>
#
# Examples:
#   bash scripts/remove-app.sh notes
#   bash scripts/remove-app.sh api
#
# What it does:
#   1. Stops and removes the container
#   2. Removes the service block from docker-compose.yml
#   3. Removes the server block from nginx/nginx.conf
#   4. Reloads nginx
#
# What it does NOT do:
#   - Delete named Docker volumes (data is kept — remove manually if needed)
#   - Delete bind-mount app data in apps/<name>/
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

if [ -z "$APP_NAME" ]; then
    echo ""
    fail "Usage: remove-app.sh <name>"
fi

# Protect core services from accidental removal
PROTECTED="nginx ngrok portainer uptime-kuma landing hello"
for svc in $PROTECTED; do
    if [ "$APP_NAME" = "$svc" ]; then
        fail "'$APP_NAME' is a core Caktus service and cannot be removed with this script."
    fi
done

# Check app actually exists
if ! grep -q "container_name: caktus-${APP_NAME}" "$COMPOSE_FILE" 2>/dev/null; then
    fail "App 'caktus-${APP_NAME}' not found in docker-compose.yml"
fi

echo ""
echo "🌵 Removing app from Caktus"
echo "════════════════════════════════════════"
echo "  App: $APP_NAME"
echo ""
warn "This will stop and remove caktus-${APP_NAME}."
warn "Docker volumes and apps/${APP_NAME}/ data are NOT deleted."
echo ""
read -rp "  Continue? [y/N] " CONFIRM
[ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "Aborted."; exit 0; }
echo ""

# ─── Step 1: Stop and remove container ───────────────────────────────
info "Step 1/3: Stopping container..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" stop "$APP_NAME" 2>/dev/null || true
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" rm -f "$APP_NAME" 2>/dev/null || true
log "Container caktus-${APP_NAME} stopped and removed"

# ─── Step 2: Remove from docker-compose.yml ──────────────────────────
info "Step 2/3: Removing service from docker-compose.yml..."
python3 - "$COMPOSE_FILE" "$APP_NAME" << 'PYEOF'
import sys
import re

compose_file = sys.argv[1]
app_name = sys.argv[2]

with open(compose_file, 'r') as f:
    content = f.read()

# Remove the service block — matches from the comment header to the next
# top-level service definition or volumes block
pattern = rf'\n  # ── {re.escape(app_name)} ─+\n  {re.escape(app_name)}:.*?(?=\n  # ──|\nvolumes:|\Z)'
new_content = re.sub(pattern, '', content, flags=re.DOTALL)

if new_content == content:
    # Fallback: remove without comment header
    pattern2 = rf'\n  {re.escape(app_name)}:.*?(?=\n  \S|\nvolumes:|\Z)'
    new_content = re.sub(pattern2, '', content, flags=re.DOTALL)

with open(compose_file, 'w') as f:
    f.write(new_content)

print("  Removed service block")
PYEOF

log "Service removed from docker-compose.yml"

# ─── Step 3: Remove from nginx.conf ──────────────────────────────────
info "Step 3/3: Removing route from nginx.conf..."
python3 - "$NGINX_FILE" "$APP_NAME" << 'PYEOF'
import sys
import re

nginx_file = sys.argv[1]
app_name = sys.argv[2]

with open(nginx_file, 'r') as f:
    content = f.read()

# Remove the nginx server block (with optional comment header)
pattern = rf'\n    # ── {re.escape(app_name)} [─]+\n    server \{{.*?\n    \}}'
new_content = re.sub(pattern, '', content, flags=re.DOTALL)

if new_content == content:
    # Fallback: remove without comment header
    pattern2 = rf'\n    server \{{\n        listen 80;\n        server_name {re.escape(app_name)}\.caktus\.local;.*?\n    \}}'
    new_content = re.sub(pattern2, '', content, flags=re.DOTALL)

with open(nginx_file, 'w') as f:
    f.write(new_content)

print("  Removed nginx server block")
PYEOF

log "Route removed from nginx.conf"

# Reload nginx
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart nginx
log "nginx reloaded"

# ─── Done ────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
log "App '${APP_NAME}' removed!"
echo ""
warn "Volume/data cleanup (if needed):"
echo "  • Docker volume:  docker volume rm caktus_${APP_NAME}_data"
echo "  • App data:       rm -rf $CAKTUS_DIR/apps/${APP_NAME}"
echo ""
