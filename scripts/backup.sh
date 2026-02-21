#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# backup.sh — Backs up all Caktus Docker volumes and app data
#
# What it backs up:
#   - All named Docker volumes (portainer, uptime-kuma data, etc.)
#   - ~/caktus/apps/ directory (bind-mount app data)
#   - ~/caktus/caddy/Caddyfile (routing config)
#   - ~/caktus/docker-compose.yml
#
# What it does NOT back up:
#   - .env (contains secrets — back up manually and securely)
#   - Caddy TLS certs (auto-reissued by Let's Encrypt if lost)
#
# Usage:
#   bash ~/caktus/scripts/backup.sh              # manual run
#   # Add to crontab for automatic daily backups:
#   # 0 3 * * * bash ~/caktus/scripts/backup.sh >> ~/caktus/logs/backup.log 2>&1
#
# Backup location: ~/caktus/backups/YYYY-MM-DD_HH-MM/
# Retention: keeps last 7 backups (older ones auto-deleted)
# ─────────────────────────────────────────────────────────────────────────────
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_env_file "$@"

BACKUP_ROOT="$CAKTUS_DIR/backups"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
RETAIN_DAYS=7

echo ""
echo "🌵 Caktus Backup — $TIMESTAMP"
echo "════════════════════════════════════════"
echo ""

# ─── Create backup directory ─────────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
log "Backup directory: $BACKUP_DIR"

# ─── 1. Config files ─────────────────────────────────────────────────────────
info "1/4: Backing up config files..."
cp "$CAKTUS_DIR/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml"
cp "$CAKTUS_DIR/caddy/Caddyfile"    "$BACKUP_DIR/Caddyfile"
[ -f "$CAKTUS_DIR/.env.example" ] && cp "$CAKTUS_DIR/.env.example" "$BACKUP_DIR/.env.example"
log "Config files backed up"
warn ".env NOT backed up (contains secrets — store separately and securely)"

# ─── 2. App data (bind mounts) ───────────────────────────────────────────────
info "2/4: Backing up apps/ directory..."
if [ -d "$CAKTUS_DIR/apps" ] && [ "$(ls -A "$CAKTUS_DIR/apps" 2>/dev/null)" ]; then
    tar -czf "$BACKUP_DIR/apps.tar.gz" -C "$CAKTUS_DIR" apps/
    SIZE=$(du -sh "$BACKUP_DIR/apps.tar.gz" | cut -f1)
    log "apps/ → apps.tar.gz ($SIZE)"
else
    log "apps/ is empty — skipping"
fi

# ─── 3. Docker volumes ───────────────────────────────────────────────────────
info "3/4: Backing up Docker volumes..."
VOLUMES=$(docker volume ls --filter "name=caktus" --format "{{.Name}}" 2>/dev/null)

if [ -z "$VOLUMES" ]; then
    warn "No caktus_* Docker volumes found"
else
    mkdir -p "$BACKUP_DIR/volumes"
    for VOL in $VOLUMES; do
        VOL_BACKUP="$BACKUP_DIR/volumes/${VOL}.tar.gz"
        docker run --rm \
            -v "${VOL}:/data:ro" \
            -v "$BACKUP_DIR/volumes:/backup" \
            alpine \
            tar -czf "/backup/${VOL}.tar.gz" -C /data . 2>/dev/null
        if [ -f "$VOL_BACKUP" ]; then
            SIZE=$(du -sh "$VOL_BACKUP" | cut -f1)
            log "  Volume $VOL → ${VOL}.tar.gz ($SIZE)"
        else
            fail "  Volume $VOL → backup failed"
        fi
    done
fi

# ─── 4. Summary and manifest ─────────────────────────────────────────────────
info "4/4: Writing manifest..."
cat > "$BACKUP_DIR/MANIFEST.txt" << EOF
Caktus Backup Manifest
=======================
Timestamp : $TIMESTAMP
Hostname  : $(hostname)
Backup dir: $BACKUP_DIR

Contents:
$(find "$BACKUP_DIR" -type f | sed "s|$BACKUP_DIR/||" | sort)

Volume sizes:
$(du -sh "$BACKUP_DIR"/* 2>/dev/null | sort -h)

Notes:
- .env (secrets) was NOT backed up — store separately
- TLS certs NOT backed up — Let's Encrypt will reissue automatically
- To restore a volume: docker run --rm -v <vol>:/data -v \$(pwd):/backup alpine tar -xzf /backup/<vol>.tar.gz -C /data
EOF

TOTAL_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log "Manifest written"
log "Total backup size: $TOTAL_SIZE"

# ─── 5. Prune old backups (keep last N days) ─────────────────────────────────
info "Pruning backups older than $RETAIN_DAYS days..."
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETAIN_DAYS" -print -exec rm -rf {} \; 2>/dev/null || true
REMAINING=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l)
log "Pruning complete — $REMAINING backup(s) retained"

echo ""
echo "════════════════════════════════════════"
log "Backup complete: $BACKUP_DIR"
echo ""
echo "  To restore a Docker volume:"
echo "  docker run --rm -v <volume>:/data -v $BACKUP_DIR/volumes:/backup \\"
echo "    alpine tar -xzf /backup/<volume>.tar.gz -C /data"
echo ""
echo "  To automate daily backups (3am):"
echo "  crontab -e"
echo "  # Add: 0 3 * * * bash ~/caktus/scripts/backup.sh >> ~/caktus/logs/backup.log 2>&1"
echo ""
