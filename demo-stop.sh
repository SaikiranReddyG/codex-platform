#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CODEX PLATFORM — Demo Stop
# ═══════════════════════════════════════════════════════════════
# Cleanly shuts down all codex services in reverse order.
# ═══════════════════════════════════════════════════════════════

COMPOSE_DIR="$HOME/codex-workspace/codex-platform"
ARCH_IP="192.168.1.51"
ARCH_USER="sai"
LOG_DIR="${COMPOSE_DIR}/logs"
ARCH_LOG_DIR="/home/${ARCH_USER}/codex-workspace/codex-platform/logs"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CODEX PLATFORM — Demo Stop${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# Stop Arch services
info "Stopping Arch VM services..."
if ping -c 1 -W 2 "$ARCH_IP" &>/dev/null; then
  ssh "$ARCH_USER@$ARCH_IP" "sudo pkill -f 'python3.*main.py' 2>/dev/null; pkill -f syswatch_wrapper 2>/dev/null" 2>/dev/null
  ok "Sentinel + syswatch stopped"
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
cd "$COMPOSE_DIR" && docker compose down 2>&1 | tail -5
ok "Docker stack stopped"

echo ""
echo -e "${BOLD}  All services stopped.${NC}"
echo ""
