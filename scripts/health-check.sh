#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Caktus Health Check — runs on the laptop
# Checks: ngrok tunnel, Docker services, Caddy, disk, memory
#
# Usage: bash scripts/health-check.sh
# ─────────────────────────────────────────────────────────────────────

CAKTUS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
section() { echo ""; echo -e "${BOLD}[$1]${NC}"; }

PASS=0
FAIL=0
WARN=0

check_ok()   { ok "$1"; ((PASS++)); }
check_fail() { fail "$1"; ((FAIL++)); }
check_warn() { warn "$1"; ((WARN++)); }

echo ""
echo "🌵 CAKTUS HEALTH CHECK"
echo "════════════════════════════════════════"
echo "  $(date)"
echo ""

# ─── 1. Docker Services ──────────────────────────────────────────────
section "1 / Docker Services"
if ! command -v docker &>/dev/null; then
    check_fail "Docker not installed"
else
    SERVICES=("caktus-caddy" "caktus-ngrok" "caktus-portainer" "caktus-uptime" "caktus-hello" "caktus-landing")
    for svc in "${SERVICES[@]}"; do
        STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
        if [ "$STATUS" = "running" ]; then
            check_ok "$svc → running"
        elif [ "$STATUS" = "missing" ]; then
            check_warn "$svc → not found"
        else
            check_fail "$svc → $STATUS"
        fi
    done
fi

# ─── 2. ngrok Tunnel ─────────────────────────────────────────────────
section "2 / ngrok Tunnel"
NGROK_STATUS=$(docker inspect --format='{{.State.Status}}' caktus-ngrok 2>/dev/null || echo "missing")
if [ "$NGROK_STATUS" = "running" ]; then
    # Check ngrok logs for errors
    NGROK_ERRORS=$(docker logs caktus-ngrok 2>&1 | grep -c "ERR_" || true)
    if [ "$NGROK_ERRORS" -eq 0 ]; then
        check_ok "ngrok tunnel active (no errors)"
    else
        check_warn "ngrok tunnel running but has $NGROK_ERRORS error(s) in logs"
    fi

    # Try to get the public URL from .env
    if [ -f "$CAKTUS_DIR/.env" ]; then
        DOMAIN=$(grep "^NGROK_DOMAIN=" "$CAKTUS_DIR/.env" | cut -d= -f2)
        if [ -n "$DOMAIN" ]; then
            check_ok "Public URL: https://$DOMAIN"
        fi
    fi
else
    check_fail "ngrok tunnel is not running"
    echo "    Fix: docker compose up -d ngrok"
fi

# ─── 3. Caddy Reachability ───────────────────────────────────────────
section "3 / Caddy (localhost:80)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    check_ok "Caddy responding on :80 (HTTP 200)"
elif [ "$HTTP_CODE" != "000" ]; then
    check_warn "Caddy responded with HTTP $HTTP_CODE"
else
    check_fail "Caddy not responding on :80"
    echo "    Fix: docker compose restart caddy"
fi

# ─── 4. Public Access ────────────────────────────────────────────────
section "4 / Public Access"
if [ -f "$CAKTUS_DIR/.env" ]; then
    DOMAIN=$(grep "^NGROK_DOMAIN=" "$CAKTUS_DIR/.env" | cut -d= -f2)
    if [ -n "$DOMAIN" ]; then
        PUB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "https://$DOMAIN" 2>/dev/null || echo "000")
        if [ "$PUB_CODE" = "200" ]; then
            check_ok "Public URL reachable (HTTP 200)"
        elif [ "$PUB_CODE" != "000" ]; then
            check_warn "Public URL responded with HTTP $PUB_CODE (may be ngrok interstitial)"
        else
            check_fail "Public URL not reachable"
        fi
    else
        check_warn "NGROK_DOMAIN not set in .env"
    fi
fi

# ─── 5. Disk Usage ───────────────────────────────────────────────────
section "5 / Disk"
df -h / | tail -1 | while read -r fs size used avail pct mp; do
    PCT_NUM=$(echo "$pct" | sed 's/%//')
    if [ "$PCT_NUM" -lt 80 ]; then
        ok "Root filesystem: $used / $size ($pct used)"
        ((PASS++))
    elif [ "$PCT_NUM" -lt 90 ]; then
        warn "Root filesystem: $used / $size ($pct used) — getting full"
        ((WARN++))
    else
        fail "Root filesystem: $used / $size ($pct used) — CRITICALLY FULL"
        ((FAIL++))
    fi
done

# ─── 6. Memory ───────────────────────────────────────────────────────
section "6 / Memory"
MEM=$(free -h | grep Mem)
TOTAL=$(echo "$MEM" | awk '{print $2}')
USED=$(echo "$MEM" | awk '{print $3}')
check_ok "RAM: $USED used of $TOTAL"

# ─── 7. System Load ──────────────────────────────────────────────────
section "7 / System Load"
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
check_ok "Load average: $LOAD"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo -e "  ${GREEN}✓ $PASS passed${NC}  ${YELLOW}! $WARN warnings${NC}  ${RED}✗ $FAIL failed${NC}"
echo ""
echo "  Quick fixes:"
echo "  • Tunnel down:   docker compose restart ngrok"
echo "  • App down:      docker compose up -d"
echo "  • Logs:          docker compose logs -f [service]"
echo ""
