#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# Caktus Health Check — runs on the laptop
# Checks: WireGuard tunnel, Docker services, DNS, disk, memory
#
# Usage: bash ~/caktus/scripts/health-check.sh
# ─────────────────────────────────────────────────────────────────────
# NOTE: No set -e here — health checks must continue even when individual
# checks fail. set -e would abort the script on first failure.

CAKTUS_DIR="$HOME/caktus"
DOMAIN="caktus.duckdns.org"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
section() { echo ""; echo -e "${BOLD}[$1]${NC}"; }

echo ""
echo "🌵 CAKTUS HEALTH CHECK"
echo "════════════════════════════════════════"
echo "  $(date)"
echo ""

# ─── 1. WireGuard ────────────────────────────────────────────────────
section "1 / WireGuard"
if sudo wg show wg0 &>/dev/null; then
    ok "wg0 interface is up"
    HANDSHAKE=$(sudo wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}')
    if [ -n "$HANDSHAKE" ] && [ "$HANDSHAKE" != "0" ]; then
        AGE=$(( $(date +%s) - HANDSHAKE ))
        if [ "$AGE" -lt 180 ]; then
            ok "Last handshake: ${AGE}s ago (healthy)"
        elif [ "$AGE" -lt 600 ]; then
            warn "Last handshake: ${AGE}s ago (slightly stale)"
        else
            fail "Last handshake: ${AGE}s ago (tunnel may be dead)"
        fi
    else
        warn "No handshake yet — VPS may not be up"
    fi
else
    fail "wg0 interface is DOWN"
    echo "    Fix: sudo systemctl restart wg-quick@wg0"
fi

# ─── 2. Tunnel Ping ──────────────────────────────────────────────────
section "2 / Tunnel Ping (10.0.0.1)"
if ping -c 2 -W 2 10.0.0.1 &>/dev/null; then
    RTT=$(ping -c 2 -W 2 10.0.0.1 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    ok "VPS reachable (avg RTT: ${RTT}ms)"
else
    fail "Cannot ping VPS (10.0.0.1)"
    echo "    Fix: sudo systemctl restart wg-quick@wg0"
fi

# ─── 3. Docker Services ──────────────────────────────────────────────
section "3 / Docker Services"
if ! command -v docker &>/dev/null; then
    fail "Docker not installed"
else
    SERVICES=("caktus-caddy" "caktus-duckdns" "caktus-portainer" "caktus-hello")
    for svc in "${SERVICES[@]}"; do
        STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
        if [ "$STATUS" = "running" ]; then
            ok "$svc → running"
        elif [ "$STATUS" = "missing" ]; then
            warn "$svc → not found (may not be started yet)"
        else
            fail "$svc → $STATUS"
        fi
    done

    # Check for any exited containers in the project
    EXITED=$(docker compose -f "$CAKTUS_DIR/docker-compose.yml" ps --filter status=exited -q 2>/dev/null | wc -l)
    if [ "$EXITED" -gt 0 ]; then
        fail "$EXITED container(s) have exited unexpectedly"
        echo "    Fix: docker compose logs -f"
    fi
fi

# ─── 4. Caddy Reachability ───────────────────────────────────────────
section "4 / Caddy (localhost:80)"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://localhost/ 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    ok "Caddy responding on :80 (HTTP 200)"
elif [ "$HTTP_CODE" != "000" ]; then
    warn "Caddy responded with HTTP $HTTP_CODE"
else
    fail "Caddy not responding on :80"
    echo "    Fix: docker compose restart caddy"
fi

# ─── 5. DNS ──────────────────────────────────────────────────────────
section "5 / DNS ($DOMAIN)"
if command -v dig &>/dev/null; then
    RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null | head -1)
    if [ -n "$RESOLVED" ]; then
        ok "$DOMAIN → $RESOLVED"
        # Check if .env has VPS_IP and compare
        if [ -f "$CAKTUS_DIR/.env" ]; then
            VPS_IP=$(grep "^VPS_IP=" "$CAKTUS_DIR/.env" | cut -d= -f2)
            if [ -n "$VPS_IP" ] && [ "$RESOLVED" = "$VPS_IP" ]; then
                ok "DNS points to correct VPS IP"
            elif [ -n "$VPS_IP" ]; then
                warn "DNS resolves to $RESOLVED but VPS_IP in .env is $VPS_IP"
            fi
        fi
    else
        fail "Cannot resolve $DOMAIN"
        echo "    Check DuckDNS dashboard — is the token valid?"
    fi
else
    warn "dig not installed, skipping DNS check"
fi

# ─── 6. Disk Usage ───────────────────────────────────────────────────
section "6 / Disk"
df -h / | tail -1 | while read -r fs size used avail pct mp; do
    PCT_NUM=${pct/\%/}
    if [ "$PCT_NUM" -lt 80 ]; then
        ok "Root filesystem: $used / $size ($pct used)"
    elif [ "$PCT_NUM" -lt 90 ]; then
        warn "Root filesystem: $used / $size ($pct used) — getting full"
    else
        fail "Root filesystem: $used / $size ($pct used) — CRITICALLY FULL"
    fi
done

# ─── 7. Memory ───────────────────────────────────────────────────────
section "7 / Memory"
MEM=$(free -h | grep Mem)
TOTAL=$(echo "$MEM" | awk '{print $2}')
USED=$(echo "$MEM" | awk '{print $3}')
ok "RAM: $USED used of $TOTAL"

# ─── 8. System Load ──────────────────────────────────────────────────
section "8 / System Load"
LOAD=$(uptime | awk -F'load average:' '{print $2}' | xargs)
ok "Load average: $LOAD"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo ""
echo "  Quick fixes:"
echo "  • Most issues:   sudo systemctl restart wg-quick@wg0"
echo "  • App down:      docker compose up -d"
echo "  • Caddy config:  docker exec caktus-caddy caddy reload --config /etc/caddy/Caddyfile"
echo "  • Logs:          docker compose logs -f [service]"
echo ""
