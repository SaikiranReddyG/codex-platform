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
LOG_DIR="${COMPOSE_DIR}/logs"

mkdir -p "$LOG_DIR"

METRICS_RECEIVER_LOG="${LOG_DIR}/metrics_receiver.log"
N8N_WF_API_FILE="${LOG_DIR}/codex_n8n_workflows_api.json"
SELFTEST_TRIGGER_FILE="${LOG_DIR}/codex_selftest_trigger.json"
SENTINEL_START_ERR_FILE="${LOG_DIR}/sentinel_start_err.txt"

# Arch-side logs (written on the Arch VM)
ARCH_LOG_DIR="/home/${ARCH_USER}/codex-workspace/codex-platform/logs"
ARCH_SYSWATCH_LOG="${ARCH_LOG_DIR}/syswatch.log"
ARCH_SENTINEL_STDOUT_LOG="${ARCH_LOG_DIR}/sentinel_stdout.log"

SELF_TEST=0
if [ "$1" = "--self-test" ]; then
  SELF_TEST=1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step=0
total=6
if [ "$SELF_TEST" -eq 1 ]; then
  total=7
fi
CRITICAL_FAILURES=0
WARNINGS=0

header() {
  ((step++))
  echo ""
  echo -e "${BOLD}${CYAN}[$step/$total]${NC} ${BOLD}$1${NC}"
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; ((WARNINGS++)); }
info() { echo -e "  ${CYAN}→${NC} $1"; }
critical_fail() { fail "$1"; ((CRITICAL_FAILURES++)); }

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

wait_http_ready() {
  local url=$1
  local max_wait=$2
  local elapsed=0
  local code
  while [ $elapsed -lt $max_wait ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo 000)
    # 200: healthy endpoint up. 401/403: service is up but auth-protected.
    if [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "403" ]; then
      echo "$code"
      return 0
    fi
    sleep 1
    ((elapsed++))
  done
  echo "${code:-000}"
  return 1
}

get_workflow_active_flag() {
  local json_file=$1
  local workflow_name=$2

  if command -v jq &>/dev/null; then
    jq -r --arg wf "$workflow_name" '.data[]? | select(.name == $wf) | .active' "$json_file" 2>/dev/null | head -n 1
    return 0
  fi

  awk -v wf="$workflow_name" '
    BEGIN { RS="\\{"; FS="\n" }
    $0 ~ "\"name\"[[:space:]]*:[[:space:]]*\"" wf "\"" {
      if ($0 ~ "\"active\"[[:space:]]*:[[:space:]]*true")  { print "true";  exit }
      if ($0 ~ "\"active\"[[:space:]]*:[[:space:]]*false") { print "false"; exit }
    }
  ' "$json_file" 2>/dev/null | head -n 1
}

get_workflow_active_flag_db() {
  local db_file=$1
  local workflow_name=$2

  if [ ! -f "$db_file" ] || ! command -v sqlite3 &>/dev/null; then
    return 1
  fi

  sqlite3 "$db_file" "SELECT active FROM workflow_entity WHERE name = '$workflow_name' ORDER BY updatedAt DESC LIMIT 1;" 2>/dev/null | tr -d '\r' | head -n 1
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
    critical_fail "$svc did not become healthy in 30s"
  fi
done

info "Waiting for n8n HTTP readiness..."
N8N_HEALTH=$(wait_http_ready "http://localhost:5678/healthz" 45)
if [ "$N8N_HEALTH" = "200" ]; then
  ok "n8n health endpoint ready"
elif [ "$N8N_HEALTH" = "401" ] || [ "$N8N_HEALTH" = "403" ]; then
  ok "n8n HTTP ready (auth-protected response: $N8N_HEALTH)"
else
  critical_fail "n8n health endpoint failed (HTTP $N8N_HEALTH)"
fi

# Quick verify: MQTT accepts auth
if command -v mosquitto_pub &>/dev/null; then
  if mosquitto_pub -h localhost -p 1883 -u "$MQTT_USER" -P "$MQTT_PASS" -t "codex/healthcheck" -m "startup-$(date +%s)" 2>/dev/null; then
    ok "MQTT auth working"
  else
    critical_fail "MQTT auth failed — check Mosquitto config"
  fi
else
  warn "mosquitto_pub not installed; MQTT auth check skipped"
fi

# Quick verify: Redis accepts auth
RPONG=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli PING 2>/dev/null | grep -o PONG)
if [ "$RPONG" = "PONG" ]; then
  ok "Redis auth working"
else
  critical_fail "Redis auth failed"
fi

# ─── Step 2: Metrics receiver ───
header "Starting metrics_receiver.py"

# Kill existing if running
pkill -f "metrics_receiver" 2>/dev/null
sleep 1

cd "$COMPOSE_DIR"
nohup python3 -u scripts/metrics_receiver.py > "$METRICS_RECEIVER_LOG" 2>&1 &
MR_PID=$!
sleep 2

if kill -0 $MR_PID 2>/dev/null; then
  ok "metrics_receiver.py running (PID $MR_PID)"
else
  critical_fail "metrics_receiver.py failed to start"
  warn "Check: tail -n 80 $METRICS_RECEIVER_LOG"
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

# Remote sudo in this script is non-interactive. Fail early with a clear hint
# if Arch still requires a password prompt.
if ! ssh "$ARCH_USER@$ARCH_IP" "sudo -n true" &>/dev/null; then
  fail "Arch sudo requires a password prompt (non-interactive sudo is required)"
  warn "Run on Arch: sudo visudo"
  warn "Add: $ARCH_USER ALL=(ALL) NOPASSWD:ALL"
  warn "Then re-run ./demo-start.sh"
  exit 1
fi
ok "Arch sudo non-interactive check passed"

# ─── Step 4: Start Arch services ───
header "Starting Arch VM services"

# Netlab namespaces
info "Setting up netlab namespaces..."
ssh "$ARCH_USER@$ARCH_IP" "bash -c 'cd ~/codex-workspace/netlab && sudo -n ./lab/setup.sh'" 2>&1 | tail -3
NS_COUNT=$(ssh "$ARCH_USER@$ARCH_IP" "sudo -n ip netns list 2>/dev/null | wc -l" 2>/dev/null)
if [ "$NS_COUNT" -gt 0 ] 2>/dev/null; then
  ok "Netlab namespaces ready ($NS_COUNT)"
else
  critical_fail "Netlab namespaces are not set up"
fi

# Syswatch wrapper
info "Starting syswatch_wrapper..."
SW_PID=$(ssh "$ARCH_USER@$ARCH_IP" "bash -c 'mkdir -p \"$ARCH_LOG_DIR\"; pkill -f syswatch_wrapper 2>/dev/null; nohup python3 -u ~/codex-workspace/codex-platform/syswatch_wrapper.py > \"$ARCH_SYSWATCH_LOG\" 2>&1 & echo \$!'")
sleep 2
if [ -n "$SW_PID" ] && ssh "$ARCH_USER@$ARCH_IP" "kill -0 $SW_PID 2>/dev/null" 2>/dev/null; then
  ok "syswatch_wrapper running (PID $SW_PID)"
  info "Arch syswatch log: $ARCH_SYSWATCH_LOG"
else
  info "syswatch_wrapper PID not confirmed; verifying via SQLite metrics"
  info "Arch syswatch log: $ARCH_SYSWATCH_LOG"
fi

# Sentinel
info "Starting sentinel on br-lab..."
ARCH_SENT_IFACE=$(ssh "$ARCH_USER@$ARCH_IP" "ip link show br-lab >/dev/null 2>&1 && echo br-lab || echo eth0" 2>/dev/null || true)
SENT_LOG="$ARCH_SENTINEL_STDOUT_LOG"

# Avoid pkill -f in a single SSH command: it can match and kill the SSH shell
# command line itself when patterns overlap.
OLD_SENT_PIDS=$(ssh "$ARCH_USER@$ARCH_IP" "ps -eo pid,args | awk '/python3 src\\/main.py/ {print \$1}'" 2>/dev/null | tr '\n' ' ' | xargs)
if [ -n "$OLD_SENT_PIDS" ]; then
  ssh "$ARCH_USER@$ARCH_IP" "sudo -n kill $OLD_SENT_PIDS 2>/dev/null || true" >/dev/null 2>&1
fi

SENT_PID=$(ssh "$ARCH_USER@$ARCH_IP" "cd ~/codex-workspace/sentinel && mkdir -p \"$ARCH_LOG_DIR\" && rm -f \"$SENT_LOG\"; nohup sudo -n python3 -u src/main.py -c config.yaml -i $ARCH_SENT_IFACE --no-dashboard > \"$SENT_LOG\" 2>&1 < /dev/null & echo \$!" 2>"$SENTINEL_START_ERR_FILE" | tr -d '[:space:]')
sleep 3
SENT_CMD=$(ssh "$ARCH_USER@$ARCH_IP" "ps -eo pid,args | grep -E 'python3 .*(sentinel/src/main.py|src/main.py)' | grep -v -E 'grep|pgrep' | head -n 1" 2>/dev/null || true)
if [ -n "$SENT_CMD" ]; then
  ok "sentinel running (iface=$ARCH_SENT_IFACE)"
  info "sentinel proc: $SENT_CMD"
  info "Arch sentinel stdout log: $SENT_LOG"
else
  critical_fail "sentinel is not running after startup"
  if [ -s "$SENTINEL_START_ERR_FILE" ]; then
    warn "startup stderr: $(tail -n 1 "$SENTINEL_START_ERR_FILE")"
  fi
  warn "Check on Arch: tail -n 80 $SENT_LOG"
fi

SENT_LOG_BYTES=$(ssh "$ARCH_USER@$ARCH_IP" "wc -c $SENT_LOG 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)
if [ -n "$SENT_LOG_BYTES" ] && [ "$SENT_LOG_BYTES" -gt 0 ] 2>/dev/null; then
  info "sentinel stdout log: ${SENT_LOG_BYTES} bytes"
else
  info "sentinel stdout log missing or empty"
fi

# ─── Step 5: Verify data flow ───
header "Verifying data flow"

sleep 5

# Check if syswatch metrics are arriving in SQLite (the real ingestion path)
sleep 8
RECENT_METRICS=$(sqlite3 "$COMPOSE_DIR/sqlite/codex.db" "SELECT COUNT(*) FROM metrics WHERE timestamp > datetime('now', '-5 minutes');" 2>/dev/null)
if [ "$RECENT_METRICS" -gt 0 ] 2>/dev/null; then
  ok "SQLite receiving metrics ($RECENT_METRICS in last 5 min)"
else
  # Give the MQTT subscriber a moment; avoid false negatives from timing.
  sleep 5
  RECENT_METRICS=$(sqlite3 "$COMPOSE_DIR/sqlite/codex.db" "SELECT COUNT(*) FROM metrics WHERE timestamp > datetime('now', '-5 minutes');" 2>/dev/null)
  if [ "$RECENT_METRICS" -gt 0 ] 2>/dev/null; then
    ok "SQLite receiving metrics ($RECENT_METRICS in last 5 min)"
  else
    critical_fail "No recent syswatch metrics in SQLite"
    warn "Check Pop!_OS: tail -n 80 $METRICS_RECEIVER_LOG"
    warn "Check Arch: tail -n 80 $ARCH_SYSWATCH_LOG"
  fi
fi

# Check sentinel alert stream
ALERT_COUNT=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli XLEN "stream:codex/sentinel/alerts" 2>/dev/null | grep -o '[0-9]*')
if [ "$ALERT_COUNT" -gt 0 ] 2>/dev/null; then
  ok "Alert stream has $ALERT_COUNT entries"
else
  info "Alert stream has $ALERT_COUNT entries (expected until first attack)"
fi

# Verify runtime workflow state in n8n API (not just local JSON file).
N8N_WF_API_STATUS=$(curl -s -o "$N8N_WF_API_FILE" -w "%{http_code}" http://localhost:5678/api/v1/workflows 2>/dev/null || echo 000)

if [ "$N8N_WF_API_STATUS" = "200" ]; then
  ALERT_TRIAGE_ACTIVE=$(get_workflow_active_flag "$N8N_WF_API_FILE" "alert triage workflow")
  RED_TEAM_ACTIVE=$(get_workflow_active_flag "$N8N_WF_API_FILE" "red-team-trigger-v2")

  if [ "$ALERT_TRIAGE_ACTIVE" = "true" ]; then
    ok "n8n runtime: alert triage workflow is active"
  elif [ "$ALERT_TRIAGE_ACTIVE" = "false" ]; then
    critical_fail "n8n runtime: alert triage workflow is inactive"
  else
    critical_fail "n8n runtime: alert triage workflow not found"
  fi

  if [ "$RED_TEAM_ACTIVE" = "true" ]; then
    ok "n8n runtime: red-team-trigger-v2 is active"
  elif [ "$RED_TEAM_ACTIVE" = "false" ]; then
    warn "n8n runtime: red-team-trigger-v2 is inactive"
  else
    warn "n8n runtime: red-team-trigger-v2 not found"
  fi
elif [ "$N8N_WF_API_STATUS" = "401" ] || [ "$N8N_WF_API_STATUS" = "403" ]; then
  info "n8n workflows API requires auth (HTTP $N8N_WF_API_STATUS); checking runtime DB fallback"

  N8N_DB_FILE="$COMPOSE_DIR/n8n-data/database.sqlite"
  ALERT_TRIAGE_ACTIVE_DB=$(get_workflow_active_flag_db "$N8N_DB_FILE" "alert triage workflow")
  RED_TEAM_ACTIVE_DB=$(get_workflow_active_flag_db "$N8N_DB_FILE" "red-team-trigger-v2")

  if [ "$ALERT_TRIAGE_ACTIVE_DB" = "1" ]; then
    ok "n8n runtime DB: alert triage workflow is active"
  elif [ "$ALERT_TRIAGE_ACTIVE_DB" = "0" ]; then
    critical_fail "n8n runtime DB: alert triage workflow is inactive"
  elif [ -f "$N8N_DB_FILE" ]; then
    critical_fail "n8n runtime DB: alert triage workflow not found"
  else
    warn "n8n runtime DB not found at $N8N_DB_FILE"
    if grep -q '"active": true' "$COMPOSE_DIR/n8n-workflows/alert_triage_workflow.json" 2>/dev/null; then
      info "fallback: alert_triage_workflow.json marked active"
    else
      warn "fallback: alert_triage_workflow.json inactive; Discord triage likely disabled"
    fi
  fi

  if [ "$RED_TEAM_ACTIVE_DB" = "1" ]; then
    ok "n8n runtime DB: red-team-trigger-v2 is active"
  elif [ "$RED_TEAM_ACTIVE_DB" = "0" ]; then
    warn "n8n runtime DB: red-team-trigger-v2 is inactive"
  elif [ -n "$RED_TEAM_ACTIVE_DB" ]; then
    warn "n8n runtime DB: red-team-trigger-v2 status unknown"
  fi
else
  critical_fail "n8n workflows API check failed (HTTP $N8N_WF_API_STATUS)"
fi

if [ "$SELF_TEST" -eq 1 ]; then
  header "Self-test: Trigger and validate alerts"
  BEFORE_ALERT_COUNT=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli XLEN "stream:codex/sentinel/alerts" 2>/dev/null | tr -d '\r')
  if ! curl -sS http://localhost:5678/webhook/red-team >"$SELFTEST_TRIGGER_FILE" 2>/dev/null; then
    critical_fail "Self-test trigger failed (n8n webhook unreachable)"
  else
    ok "Self-test trigger submitted"
  fi

  sleep 4
  AFTER_ALERT_COUNT=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli XLEN "stream:codex/sentinel/alerts" 2>/dev/null | tr -d '\r')

  if [ -n "$BEFORE_ALERT_COUNT" ] && [ -n "$AFTER_ALERT_COUNT" ] && [ "$AFTER_ALERT_COUNT" -gt "$BEFORE_ALERT_COUNT" ] 2>/dev/null; then
    ok "Self-test passed: alert stream incremented ($BEFORE_ALERT_COUNT -> $AFTER_ALERT_COUNT)"
  else
    critical_fail "Self-test failed: alert stream did not increment"
    warn "Trigger response: $(cat "$SELFTEST_TRIGGER_FILE" 2>/dev/null)"
  fi
fi

# ─── Step 6: Done ───
header "Demo ready"

echo ""
if [ "$CRITICAL_FAILURES" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  ✓ ALL SYSTEMS GO${NC}"
  echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
else
  echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${RED}  ✗ STARTUP INCOMPLETE${NC}"
  echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
fi
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

echo -e "  ${BOLD}Summary:${NC} critical_failures=$CRITICAL_FAILURES warnings=$WARNINGS"

if [ "$CRITICAL_FAILURES" -gt 0 ]; then
  exit 1
fi
