#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# logs.sh — Centralized, pretty log viewer for all Caktus services
#
# Usage:
#   bash scripts/logs.sh           # show last 50 lines from all services
#   bash scripts/logs.sh caddy     # tail logs for caddy only
#   bash scripts/logs.sh -f        # follow all logs (live stream)
#   bash scripts/logs.sh errors    # show only ERROR lines across all services
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

resolve_env_file "$@"
strip_env_file_args ARGS "$@"
set -- "${ARGS[@]+"${ARGS[@]}"}"

COMPOSE_FILE="$CAKTUS_DIR/docker-compose.yml"
SERVICES="caddy ngrok portainer uptime-kuma landing hello"

usage() {
    echo ""
    echo "Usage: bash scripts/logs.sh [service|flag]"
    echo ""
    echo "  No args      → last 50 lines from all services"
    echo "  <service>    → tail that service (caddy, portainer, uptime-kuma, etc.)"
    echo "  -f           → follow all services live"
    echo "  errors       → grep ERROR/WARN across all services"
    echo "  status       → show container status summary"
    echo ""
}

print_header() {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  🌵 Caktus Logs — $(date)${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${NC}"
    echo ""
}

case "$1" in

    # Follow all logs live
    -f|--follow)
        print_header
        echo -e "${CYAN}Following all services (Ctrl+C to stop)...${NC}"
        echo ""
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f --tail 10
        ;;

    # Show only errors across all services
    errors|error|err)
        print_header
        echo -e "${RED}Errors & Warnings across all services:${NC}"
        echo ""
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail 500 2>&1 | \
            grep -iE 'error|warn|fail|fatal|panic|exception|critical' | \
            grep -v '^#' | \
            head -100 || echo "  No errors found in last 500 lines"
        ;;

    # Status summary
    status)
        print_header
        echo -e "${BOLD}Container Status:${NC}"
        echo ""
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
        echo ""
        echo -e "${BOLD}Resource Usage:${NC}"
        docker stats --no-stream --format \
            "  {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | \
            grep caktus | \
            column -t || echo "  (no containers running)"
        ;;

    # Help
    -h|--help|help)
        usage
        ;;

    # Specific service
    caddy|portainer|ngrok|uptime-kuma|uptime|hello|landing)
        SVC="$1"
        [ "$SVC" = "uptime" ] && SVC="uptime-kuma"
        print_header
        echo -e "${CYAN}Logs for: $SVC${NC}"
        echo ""
        docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail 100 -f "$SVC"
        ;;

    # Default: show recent from all services
    "")
        print_header
        echo -e "${MUTED}Last 50 lines from each service:${NC}"

        for svc in $SERVICES; do
            CONTAINER="caktus-${svc}"
            STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "not found")

            if [ "$STATUS" = "running" ]; then
                COLOR=$GREEN
            elif [ "$STATUS" = "not found" ]; then
                COLOR=$MUTED
            else
                COLOR=$RED
            fi

            echo -e "${BOLD}┌── $svc ${COLOR}[$STATUS]${NC}${BOLD} ──────────────────────────────${NC}"
            if [ "$STATUS" = "running" ]; then
                docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail 8 "$svc" 2>/dev/null | \
                    sed 's/^/│  /' || true
            else
                echo "│  (not running)"
            fi
            echo ""
        done
        ;;

    *)
        echo -e "${RED}Unknown service or flag: $1${NC}"
        usage
        exit 1
        ;;
esac
