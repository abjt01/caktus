#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# common.sh — Shared library for all Caktus scripts
#
# Source this from any script in scripts/:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides:
#   CAKTUS_DIR            — project root (absolute, derived from this file's location)
#   Color vars            — BOLD GREEN YELLOW RED BLUE CYAN MUTED NC
#   log / warn / info / fail / section
#   resolve_env_file "$@" — sets ENV_FILE; falls back to $CAKTUS_DIR/.env
#   strip_env_file_args RESULT_VAR "$@" — removes --env-file <path> from arg list
# ─────────────────────────────────────────────────────────────────────

# Derive CAKTUS_DIR from this file's own location: scripts/lib/common.sh → ../..
# BASH_SOURCE[0] always points to common.sh itself, not the calling script.
CAKTUS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ─── Colors ──────────────────────────────────────────────────────────
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MUTED='\033[0;90m'
NC='\033[0m'

# ─── Log functions ────────────────────────────────────────────────────
log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BOLD}[→]${NC} $1"; }
fail()    { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo ""; echo -e "${BOLD}[$1]${NC}"; }

# ─── resolve_env_file ─────────────────────────────────────────────────
# Scans "$@" for --env-file <path>. Sets ENV_FILE.
# Falls back to $CAKTUS_DIR/.env if not supplied.
# Exits with a clear error if the resolved file does not exist.
#
# Usage: resolve_env_file "$@"
resolve_env_file() {
    ENV_FILE=""
    local args=("$@")
    local i=0
    while [ $i -lt ${#args[@]} ]; do
        if [ "${args[$i]}" = "--env-file" ]; then
            i=$(( i + 1 ))
            ENV_FILE="${args[$i]}"
            break
        fi
        i=$(( i + 1 ))
    done
    if [ -z "$ENV_FILE" ]; then
        ENV_FILE="$CAKTUS_DIR/.env"
    fi
    if [ ! -f "$ENV_FILE" ]; then
        fail "env file not found: $ENV_FILE"
    fi
}

# ─── strip_env_file_args ──────────────────────────────────────────────
# Removes --env-file <path> from an argument list, writing the filtered
# result into a named array variable (requires bash 4.3+ nameref).
# Ubuntu 22.04 ships bash 5.1 — this is safe.
#
# Usage: strip_env_file_args RESULT_VARNAME "$@"
strip_env_file_args() {
    local -n _result_ref=$1; shift
    _result_ref=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--env-file" ]; then
            shift 2
            continue
        fi
        _result_ref+=("$1")
        shift
    done
}
