#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CODEX PLATFORM — Demo Stop
# ═══════════════════════════════════════════════════════════════
# Cleanly shuts down all codex services in reverse order.
# ═══════════════════════════════════════════════════════════════

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${CODEX_COMPOSE_DIR:-$SCRIPT_DIR}"
ENV_FILE="${CODEX_ENV_FILE:-$COMPOSE_DIR/.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

COMPOSE_DIR="${CODEX_COMPOSE_DIR:-$SCRIPT_DIR}"
require_env() {
  local var_name="$1"
  if [ -z "${!var_name:-}" ]; then
    echo "[!] Missing required environment variable: $var_name"
    echo "    Set it in $ENV_FILE or export it before running."
    exit 2
  fi
}

require_env CODEX_ARCH_IP
require_env CODEX_ARCH_USER
require_env CODEX_ARCH_WORKSPACE
require_env CODEX_ARCH_LOG_DIR

ARCH_IP="$CODEX_ARCH_IP"
ARCH_USER="$CODEX_ARCH_USER"
ARCH_WORKSPACE="$CODEX_ARCH_WORKSPACE"
LOG_DIR="${COMPOSE_DIR}/logs"
ARCH_LOG_DIR="$CODEX_ARCH_LOG_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

QUIET=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: ./demo-stop.sh [--quiet] [--verbose]

  --quiet     Minimal output
  --verbose   Show docker compose down output
EOF
}

for arg in "$@"; do
  case "$arg" in
    --quiet|-q)  QUIET=1 ;;
    --verbose|-v) VERBOSE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; usage; exit 2 ;;
  esac
done

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { [ "$QUIET" -eq 1 ] && return 0; echo -e "  ${CYAN}→${NC} $1"; }

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CODEX PLATFORM — Demo Stop${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# Stop Arch services
info "Stopping Arch VM services..."
if ping -c 1 -W 2 "$ARCH_IP" &>/dev/null; then
  # Stop only the specific long-running demo processes we start.
  ssh "$ARCH_USER@$ARCH_IP" "sudo pkill -f 'python3 .*sentinel/src/main.py|python3 .*src/main.py -c config.yaml' 2>/dev/null; pkill -f syswatch_wrapper 2>/dev/null" 2>/dev/null
  ok "Arch sensors stopped (sentinel + syswatch_wrapper)"
  info "Arch logs remain at: $ARCH_LOG_DIR"
else
  info "Arch VM not reachable — skipping"
fi

# Stop metrics receiver
info "Stopping metrics_receiver..."
pkill -f metrics_receiver 2>/dev/null
ok "metrics_receiver stopped"

# Note: logs now live under $LOG_DIR (not /tmp)

# Stop Docker stack
info "Stopping Docker stack..."
if [ "$VERBOSE" -eq 1 ] && [ "$QUIET" -eq 0 ]; then
  if cd "$COMPOSE_DIR" && docker compose down; then
    :
  else
    echo -e "  ${RED}✗${NC} Docker compose down failed (check docker permissions)"
  fi
else
  if cd "$COMPOSE_DIR" && docker compose down 2>&1 | tail -5; then
    :
  else
    echo -e "  ${RED}✗${NC} Docker compose down failed (check docker permissions)"
  fi
fi
ok "Docker stack stopped"

echo ""
echo -e "${BOLD}  All services stopped.${NC}"
if [ "$QUIET" -eq 0 ]; then
  echo -e "${BOLD}  Logs (Pop!_OS):${NC}  $LOG_DIR"
  echo -e "${BOLD}  Logs (Arch):${NC}    $ARCH_LOG_DIR"
fi
echo ""
