#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CODEX PLATFORM — Demo Start
# ═══════════════════════════════════════════════════════════════
# One command to go from cold boot to demo-ready.
# Run on Pop!_OS: ./demo-start.sh
#
# What it does (in order):
#   1. Start Docker stack (Mosquitto, Redis, n8n, Grafana)
#   2. Wait for containers to be healthy
#   3. Start metrics_receiver.py on Pop!_OS
#   4. SSH to Arch VM and start netlab, syswatch, sentinel
#   5. Verify data is flowing
#   6. Print demo URLs
# ═══════════════════════════════════════════════════════════════

set -o pipefail

COMPOSE_DIR="$HOME/codex-workspace/codex-platform"
ARCH_IP="192.168.1.51"
ARCH_USER="sai"
MQTT_USER="codex"
MQTT_PASS="codex-mqtt-2026"
REDIS_PASS="codex-redis-2026"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step=0
total=6

header() {
  ((step++))
  echo ""
  echo -e "${BOLD}${CYAN}[$step/$total]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
info() { echo -e "  ${CYAN}→${NC} $1"; }

wait_healthy() {
  local container=$1
  local max_wait=$2
  local elapsed=0
  while [ $elapsed -lt $max_wait ]; do
    status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null)
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$container" 2>/dev/null)
    if [ "$status" = "running" ] && ([ "$health" = "healthy" ] || [ "$health" = "running" ]); then
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  return 1
}

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CODEX PLATFORM — Demo Start${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

# ─── Step 1: Docker stack ───
header "Starting Docker stack"

cd "$COMPOSE_DIR" || { fail "Cannot cd to $COMPOSE_DIR"; exit 1; }
docker compose up -d 2>&1 | tail -5
sleep 2

for svc in codex-mosquitto codex-redis codex-n8n codex-grafana; do
  info "Waiting for $svc..."
  if wait_healthy "$svc" 30; then
    ok "$svc is ready"
  else
    fail "$svc did not become healthy in 30s"
    warn "Continuing anyway..."
  fi
done

# Quick verify: MQTT accepts auth
if command -v mosquitto_pub &>/dev/null; then
  if mosquitto_pub -h localhost -p 1883 -u "$MQTT_USER" -P "$MQTT_PASS" -t "codex/healthcheck" -m "startup-$(date +%s)" 2>/dev/null; then
    ok "MQTT auth working"
  else
    fail "MQTT auth failed — check Mosquitto config"
  fi
fi

# Quick verify: Redis accepts auth
RPONG=$(docker exec codex-redis redis-cli -a "$REDIS_PASS" PING 2>/dev/null | grep -o PONG)
if [ "$RPONG" = "PONG" ]; then
  ok "Redis auth working"
else
  fail "Redis auth failed"
fi

# ─── Step 2: Metrics receiver ───
header "Starting metrics_receiver.py"

# Kill existing if running
pkill -f "metrics_receiver" 2>/dev/null
sleep 1

cd "$COMPOSE_DIR"
nohup python3 scripts/metrics_receiver.py > /tmp/metrics_receiver.log 2>&1 &
MR_PID=$!
sleep 2

if kill -0 $MR_PID 2>/dev/null; then
  ok "metrics_receiver.py running (PID $MR_PID)"
else
  fail "metrics_receiver.py failed to start"
  warn "Check: cat /tmp/metrics_receiver.log"
fi

# ─── Step 3: Check Arch VM ───
header "Connecting to Arch VM ($ARCH_IP)"

if ! ping -c 1 -W 3 "$ARCH_IP" &>/dev/null; then
  fail "Arch VM not reachable at $ARCH_IP"
  warn "Is the VM running? Start it in VirtualBox and re-run this script."
  warn "Skipping Arch setup — Pop!_OS services are running."
  echo ""
  echo -e "${YELLOW}${BOLD}  ⚠ PARTIAL START — Pop!_OS ready, Arch VM offline${NC}"
  echo ""
  echo "  Grafana:  http://localhost:3000  (admin/codex)"
  echo "  n8n:      http://localhost:5678"
  echo ""
  exit 1
fi

ok "Arch VM is reachable"

# Test SSH
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$ARCH_USER@$ARCH_IP" "echo ok" &>/dev/null; then
  # Try with password prompt
  if ! timeout 10 ssh -o ConnectTimeout=5 "$ARCH_USER@$ARCH_IP" "echo ok" &>/dev/null; then
    fail "SSH to Arch failed"
    warn "Try manually: ssh $ARCH_USER@$ARCH_IP"
    warn "Skipping Arch setup."
    echo ""
    echo -e "${YELLOW}${BOLD}  ⚠ PARTIAL START — Pop!_OS ready, Arch SSH failed${NC}"
    exit 1
  fi
fi

ok "SSH to Arch working"

# ─── Step 4: Start Arch services ───
header "Starting Arch VM services"

# Netlab namespaces
info "Setting up netlab namespaces..."
ssh "$ARCH_USER@$ARCH_IP" "bash -c 'cd ~/codex-workspace/netlab && sudo ./lab/setup.sh'" 2>&1 | tail -3
NS_COUNT=$(ssh "$ARCH_USER@$ARCH_IP" "sudo ip netns list 2>/dev/null | wc -l" 2>/dev/null)
if [ "$NS_COUNT" -gt 0 ] 2>/dev/null; then
  ok "Netlab namespaces ready ($NS_COUNT)"
else
  warn "Netlab namespaces may not be set up"
fi

# Syswatch wrapper
info "Starting syswatch_wrapper..."
ssh "$ARCH_USER@$ARCH_IP" "pkill -f syswatch_wrapper 2>/dev/null; nohup python3 ~/codex-workspace/codex-platform/syswatch_wrapper.py > /tmp/syswatch.log 2>&1 & sleep 4"
sleep 2
SW_PID=$(ssh "$ARCH_USER@$ARCH_IP" "pgrep -f syswatch_wrapper" 2>/dev/null)
if [ -n "$SW_PID" ]; then
  ok "syswatch_wrapper running (PID $SW_PID)"
else
  warn "syswatch_wrapper may not have started"
  warn "Check: ssh $ARCH_USER@$ARCH_IP cat /tmp/syswatch.log"
fi

# Sentinel
info "Starting sentinel on br-lab..."
ssh "$ARCH_USER@$ARCH_IP" "sudo pkill -f 'python3.*main.py.*sentinel' 2>/dev/null; nohup sudo python3 ~/codex-workspace/sentinel/src/main.py -i br-lab --no-dashboard > /tmp/sentinel.log 2>&1 & sleep 3"
sleep 3
SENT_PID=$(ssh "$ARCH_USER@$ARCH_IP" "pgrep -f 'python3.*main.py' 2>/dev/null | head -1" 2>/dev/null)
if [ -n "$SENT_PID" ]; then
  ok "sentinel running (PID $SENT_PID)"
else
  warn "sentinel may not have started"
  warn "Check: ssh $ARCH_USER@$ARCH_IP cat /tmp/sentinel.log"
fi

# ─── Step 5: Verify data flow ───
header "Verifying data flow"

sleep 5

# Check if syswatch metrics are arriving
METRICS_BEFORE=$(docker exec codex-redis redis-cli -a "$REDIS_PASS" XLEN "stream:codex/syswatch/metrics" 2>/dev/null | grep -o '[0-9]*')
sleep 6
METRICS_AFTER=$(docker exec codex-redis redis-cli -a "$REDIS_PASS" XLEN "stream:codex/syswatch/metrics" 2>/dev/null | grep -o '[0-9]*')

if [ -n "$METRICS_BEFORE" ] && [ -n "$METRICS_AFTER" ] && [ "$METRICS_AFTER" -gt "$METRICS_BEFORE" ] 2>/dev/null; then
  ok "Syswatch metrics flowing ($METRICS_BEFORE → $METRICS_AFTER)"
else
  warn "No new syswatch metrics detected (before: $METRICS_BEFORE, after: $METRICS_AFTER)"
fi

# Check SQLite has recent metrics
RECENT_METRICS=$(sqlite3 "$COMPOSE_DIR/sqlite/codex.db" "SELECT COUNT(*) FROM metrics WHERE timestamp > datetime('now', '-5 minutes');" 2>/dev/null)
if [ "$RECENT_METRICS" -gt 0 ] 2>/dev/null; then
  ok "SQLite receiving metrics ($RECENT_METRICS in last 5 min)"
else
  info "No metrics in SQLite yet (metrics_receiver needs a moment)"
fi

# Check sentinel alert stream
ALERT_COUNT=$(docker exec codex-redis redis-cli -a "$REDIS_PASS" XLEN "stream:codex/sentinel/alerts" 2>/dev/null | grep -o '[0-9]*')
ok "Alert stream has $ALERT_COUNT entries"

# ─── Step 6: Done ───
header "Demo ready"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✓ ALL SYSTEMS GO${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Dashboard:${NC}  http://localhost:3000  (admin / codex)"
echo -e "  ${BOLD}n8n:${NC}        http://localhost:5678"
echo -e "  ${BOLD}Red team:${NC}   curl http://localhost:5678/webhook/red-team"
echo ""
echo -e "  ${BOLD}To trigger the demo:${NC}"
echo -e "  1. Open Grafana SOC Command Center dashboard"
echo -e "  2. Open Discord #ai-lab channel"
echo -e "  3. Run: ${CYAN}curl http://localhost:5678/webhook/red-team${NC}"
echo -e "  4. Watch alerts flow: sentinel → MQTT → n8n → Discord + Grafana"
echo ""
echo -e "  ${BOLD}To stop everything:${NC}"
echo -e "  ${CYAN}./demo-stop.sh${NC}  (or manually: docker compose down)"
echo ""
