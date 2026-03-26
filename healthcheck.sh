#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CODEX PLATFORM — End-to-End Health Check
# ═══════════════════════════════════════════════════════════════
# Run on Pop!_OS. Tests every component and data flow.
# Usage: chmod +x healthcheck.sh && ./healthcheck.sh
# ═══════════════════════════════════════════════════════════════

set -o pipefail

# ─── Config ───
ARCH_IP="192.168.1.51"
ARCH_USER="sai"
POPOS_IP="192.168.1.50"
MQTT_PORT=1883
REDIS_PORT=6379
N8N_PORT=5678
GRAFANA_PORT=3000
SQLITE_DB="$HOME/codex-workspace/codex-platform/sqlite/codex.db"
COMPOSE_DIR="$HOME/codex-workspace/codex-platform"

# Auth (must match docker-compose.yml)
MQTT_USER="codex"
MQTT_PASS="codex-mqtt-2026"
REDIS_PASS="codex-redis-2026"

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; ((WARN++)); }
info() { echo -e "  ${BLUE}ℹ${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}[$1]${NC} $2"; echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"; }

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  CODEX PLATFORM — End-to-End Health Check${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "  Time: $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  Host: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo ""

# ═══════════════════════════════════════════════════════════════
# 1. DOCKER CONTAINERS
# ═══════════════════════════════════════════════════════════════
section "1/8" "Docker containers (Pop!_OS)"

if ! command -v docker &>/dev/null; then
  fail "Docker not installed"
else
  pass "Docker installed ($(docker --version | awk '{print $3}' | tr -d ','))"

  # Check compose file exists
  if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    pass "docker-compose.yml found"
  else
    fail "docker-compose.yml not found at $COMPOSE_DIR"
  fi

  # Check each container
  for svc in codex-mosquitto codex-redis codex-n8n codex-grafana; do
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null)
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$svc" 2>/dev/null)
    if [ "$status" = "running" ]; then
      if [ "$health" = "healthy" ] || [ "$health" = "no-healthcheck" ]; then
        pass "$svc — running ($health)"
      else
        warn "$svc — running but $health"
      fi
    elif [ -z "$status" ]; then
      fail "$svc — container not found"
    else
      fail "$svc — $status"
    fi
  done

  # Show uptime
  for svc in codex-mosquitto codex-redis codex-n8n codex-grafana; do
    uptime=$(docker inspect --format='{{.State.StartedAt}}' "$svc" 2>/dev/null)
    if [ -n "$uptime" ] && [ "$uptime" != "<no value>" ]; then
      info "$svc up since $(echo "$uptime" | cut -d'T' -f1,2 | cut -d'.' -f1)"
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════
# 2. MQTT BROKER (MOSQUITTO)
# ═══════════════════════════════════════════════════════════════
section "2/8" "MQTT broker (Mosquitto :$MQTT_PORT)"

# Test MQTT port is reachable
if timeout 3 bash -c "echo >/dev/tcp/localhost/$MQTT_PORT" 2>/dev/null; then
  pass "Mosquitto port $MQTT_PORT is open"
else
  fail "Mosquitto port $MQTT_PORT not reachable"
fi

# Test MQTT publish/subscribe with a test message
if command -v mosquitto_pub &>/dev/null && command -v mosquitto_sub &>/dev/null; then
  TEST_MSG="healthcheck-$(date +%s)"
  # Subscribe in background, wait for message, timeout after 3s
  timeout 3 mosquitto_sub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "codex/healthcheck" -C 1 > /tmp/mqtt_test 2>/dev/null &
  SUB_PID=$!
  sleep 0.5
  mosquitto_pub -h localhost -p $MQTT_PORT -u "$MQTT_USER" -P "$MQTT_PASS" -t "codex/healthcheck" -m "$TEST_MSG" 2>/dev/null
  wait $SUB_PID 2>/dev/null
  RECEIVED=$(cat /tmp/mqtt_test 2>/dev/null)
  if [ "$RECEIVED" = "$TEST_MSG" ]; then
    pass "MQTT pub/sub round-trip works"
  else
    fail "MQTT pub/sub test failed (sent: $TEST_MSG, received: $RECEIVED)"
  fi
  rm -f /tmp/mqtt_test
else
  warn "mosquitto_pub/sub not installed — skipping MQTT round-trip test"
  info "Install with: sudo apt install mosquitto-clients"
fi

# Check MQTT is reachable from Arch perspective (via host IP)
if timeout 3 bash -c "echo >/dev/tcp/$POPOS_IP/$MQTT_PORT" 2>/dev/null; then
  pass "Mosquitto reachable on $POPOS_IP:$MQTT_PORT (external)"
else
  warn "Mosquitto not reachable on $POPOS_IP:$MQTT_PORT — Arch VM may not be able to connect"
fi

# ═══════════════════════════════════════════════════════════════
# 3. REDIS
# ═══════════════════════════════════════════════════════════════
section "3/8" "Redis (:$REDIS_PORT)"

# Test Redis port
if timeout 3 bash -c "echo >/dev/tcp/localhost/$REDIS_PORT" 2>/dev/null; then
  pass "Redis port $REDIS_PORT is open"
else
  fail "Redis port $REDIS_PORT not reachable"
fi

# Ping Redis
REDIS_PING=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli PING 2>/dev/null | tr -d '\r')
if [ "$REDIS_PING" = "PONG" ]; then
  pass "Redis PING → PONG"
else
  fail "Redis PING failed: $REDIS_PING"
fi

# Check streams exist and get counts
for stream in "stream:codex/sentinel/alerts" "stream:codex/netlab/attacks" "stream:codex/syswatch/metrics"; do
  LEN=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli XLEN "$stream" 2>/dev/null | tr -d '\r')
  if [ -n "$LEN" ] && [ "$LEN" -gt 0 ] 2>/dev/null; then
    pass "$stream — $LEN entries"
  elif [ "$LEN" = "0" ]; then
    warn "$stream — empty (0 entries)"
  else
    warn "$stream — doesn't exist or error"
  fi
done

# Check Redis memory
REDIS_MEM=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" codex-redis redis-cli INFO memory 2>/dev/null | grep "used_memory_human" | cut -d: -f2 | tr -d '\r')
if [ -n "$REDIS_MEM" ]; then
  info "Redis memory usage: $REDIS_MEM"
fi

# ═══════════════════════════════════════════════════════════════
# 4. SQLITE DATABASE
# ═══════════════════════════════════════════════════════════════
section "4/8" "SQLite database"

if [ -f "$SQLITE_DB" ]; then
  pass "codex.db exists ($(du -h "$SQLITE_DB" | cut -f1))"

  # Check tables exist
  TABLES=$(sqlite3 "$SQLITE_DB" ".tables" 2>/dev/null)
  for tbl in events threat_intel metrics; do
    if echo "$TABLES" | grep -qw "$tbl"; then
      COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM $tbl;" 2>/dev/null)
      pass "Table '$tbl' — $COUNT rows"
    else
      fail "Table '$tbl' not found"
    fi
  done

  # Check recent events
  RECENT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM events WHERE created_at > datetime('now', '-24 hours');" 2>/dev/null)
  if [ "$RECENT" -gt 0 ] 2>/dev/null; then
    pass "Events in last 24h: $RECENT"
  else
    warn "No events in last 24h (sweep.py may not have run, or no alerts generated)"
  fi

  # Last event timestamp
  LAST_EVT=$(sqlite3 "$SQLITE_DB" "SELECT MAX(created_at) FROM events;" 2>/dev/null)
  if [ -n "$LAST_EVT" ] && [ "$LAST_EVT" != "" ]; then
    info "Last event: $LAST_EVT"
  fi

  # Last metric timestamp
  LAST_MET=$(sqlite3 "$SQLITE_DB" "SELECT MAX(timestamp) FROM metrics;" 2>/dev/null)
  if [ -n "$LAST_MET" ] && [ "$LAST_MET" != "" ]; then
    info "Last metric: $LAST_MET"
  else
    warn "No metrics in database — metrics_receiver.py may not have run"
  fi

  # Check threat_intel data
  INTEL_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM threat_intel;" 2>/dev/null)
  if [ "$INTEL_COUNT" -ge 6 ] 2>/dev/null; then
    pass "Threat intel loaded: $INTEL_COUNT entries"
  else
    warn "Threat intel: only $INTEL_COUNT entries (expected 6)"
  fi

  # Check severity distribution
  info "Severity distribution:"
  sqlite3 "$SQLITE_DB" "SELECT severity, COUNT(*) as cnt FROM events WHERE event_type='alert' GROUP BY severity ORDER BY cnt DESC;" 2>/dev/null | while IFS='|' read -r sev cnt; do
    echo -e "       $sev: $cnt"
  done

else
  fail "codex.db not found at $SQLITE_DB"
fi

# ═══════════════════════════════════════════════════════════════
# 5. N8N WORKFLOWS
# ═══════════════════════════════════════════════════════════════
section "5/8" "n8n workflows (:$N8N_PORT)"

# Test n8n port
if timeout 3 bash -c "echo >/dev/tcp/localhost/$N8N_PORT" 2>/dev/null; then
  pass "n8n port $N8N_PORT is open"
else
  fail "n8n port $N8N_PORT not reachable"
fi

# Test n8n API health
N8N_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$N8N_PORT/healthz" 2>/dev/null)
if [ "$N8N_HEALTH" = "200" ]; then
  pass "n8n health endpoint OK (200)"
else
  warn "n8n health check returned: $N8N_HEALTH"
fi

# Test red team webhook
WEBHOOK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$N8N_PORT/webhook/red-team" 2>/dev/null)
if [ "$WEBHOOK_STATUS" = "200" ] || [ "$WEBHOOK_STATUS" = "500" ]; then
  # 500 is expected if Arch is not reachable — it means the webhook triggered
  pass "Red team webhook reachable (HTTP $WEBHOOK_STATUS)"
  if [ "$WEBHOOK_STATUS" = "500" ]; then
    info "Webhook returned 500 — expected if Arch VM is not running"
  fi
else
  warn "Red team webhook returned: $WEBHOOK_STATUS"
fi

# ═══════════════════════════════════════════════════════════════
# 6. GRAFANA
# ═══════════════════════════════════════════════════════════════
section "6/8" "Grafana (:$GRAFANA_PORT)"

# Test Grafana port
if timeout 3 bash -c "echo >/dev/tcp/localhost/$GRAFANA_PORT" 2>/dev/null; then
  pass "Grafana port $GRAFANA_PORT is open"
else
  fail "Grafana port $GRAFANA_PORT not reachable"
fi

# Test Grafana API
GRAFANA_HEALTH=$(curl -s "http://localhost:$GRAFANA_PORT/api/health" 2>/dev/null)
if echo "$GRAFANA_HEALTH" | grep -q '"database": "ok"'; then
  pass "Grafana API healthy"
else
  warn "Grafana health: $GRAFANA_HEALTH"
fi

# Check datasources
DS_LIST=$(curl -s "http://admin:codex@localhost:$GRAFANA_PORT/api/datasources" 2>/dev/null)
if echo "$DS_LIST" | grep -q "redis-datasource"; then
  pass "Redis datasource configured"
else
  fail "Redis datasource not found"
fi
if echo "$DS_LIST" | grep -q "frser-sqlite-datasource"; then
  pass "SQLite datasource configured"
else
  fail "SQLite datasource not found"
fi

# Check dashboards
DASH_COUNT=$(curl -s "http://admin:codex@localhost:$GRAFANA_PORT/api/search?type=dash-db" 2>/dev/null | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
if [ -n "$DASH_COUNT" ] && [ "$DASH_COUNT" -gt 0 ] 2>/dev/null; then
  pass "Dashboards found: $DASH_COUNT"
  # List them
  curl -s "http://admin:codex@localhost:$GRAFANA_PORT/api/search?type=dash-db" 2>/dev/null | python3 -c "
import sys, json
for d in json.load(sys.stdin):
    print(f\"       • {d.get('title', '?')} (uid: {d.get('uid', '?')})\")" 2>/dev/null
else
  warn "No dashboards found"
fi

# Check plugins
if docker exec codex-grafana grafana cli plugins ls 2>/dev/null | grep -q "gapit-htmlgraphics-panel"; then
  pass "HTMLGraphics plugin installed"
else
  warn "HTMLGraphics plugin not installed"
fi

# ═══════════════════════════════════════════════════════════════
# 7. ARCH VM CONNECTIVITY
# ═══════════════════════════════════════════════════════════════
section "7/8" "Arch VM connectivity ($ARCH_IP)"

# Ping test
if ping -c 1 -W 2 "$ARCH_IP" &>/dev/null; then
  pass "Arch VM is reachable (ping OK)"
else
  fail "Arch VM not reachable at $ARCH_IP"
  info "Is the VM running? Check VirtualBox."
fi

# SSH test
if timeout 5 ssh -o BatchMode=yes -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "echo ok" &>/dev/null; then
  pass "SSH to $ARCH_USER@$ARCH_IP works"

  # Check what's running on Arch
  echo ""
  info "Checking Arch VM processes..."

  # Check sentinel
  SENTINEL_PID=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "pgrep -f 'python3.*main.py.*sentinel'" 2>/dev/null)
  if [ -n "$SENTINEL_PID" ]; then
    pass "sentinel is running (PID $SENTINEL_PID)"
  else
    warn "sentinel is NOT running"
    info "Start with: cd ~/codex-workspace/sentinel && sudo python3 src/main.py -i br-lab --no-dashboard"
  fi

  # Check syswatch_wrapper
  SYSWATCH_PID=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "pgrep -f 'syswatch_wrapper'" 2>/dev/null)
  if [ -n "$SYSWATCH_PID" ]; then
    pass "syswatch_wrapper is running (PID $SYSWATCH_PID)"
  else
    warn "syswatch_wrapper is NOT running"
    info "Start with: python3 ~/codex-workspace/codex-platform/syswatch_wrapper.py &"
  fi

  # Check netlab namespaces
  NS_COUNT=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "sudo ip netns list 2>/dev/null | wc -l" 2>/dev/null)
  if [ "$NS_COUNT" -gt 0 ] 2>/dev/null; then
    pass "Netlab namespaces exist ($NS_COUNT)"
  else
    warn "Netlab namespaces not set up"
    info "Run: cd ~/codex-workspace/netlab && sudo ./lab/setup.sh"
  fi

  # Check br-lab bridge
  BRLAB=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "ip link show br-lab 2>/dev/null | head -1" 2>/dev/null)
  if [ -n "$BRLAB" ]; then
    pass "br-lab bridge exists"
  else
    warn "br-lab bridge not found (netlab setup.sh not run)"
  fi

  # Check MQTT connectivity from Arch → Pop!_OS
  MQTT_FROM_ARCH=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "timeout 2 bash -c 'echo >/dev/tcp/$POPOS_IP/$MQTT_PORT' 2>/dev/null && echo 'ok' || echo 'fail'" 2>/dev/null)
  if [ "$MQTT_FROM_ARCH" = "ok" ]; then
    pass "Arch → Pop!_OS MQTT ($POPOS_IP:$MQTT_PORT) reachable"
  else
    fail "Arch cannot reach MQTT on $POPOS_IP:$MQTT_PORT"
  fi

  # Check Redis connectivity from Arch → Pop!_OS
  REDIS_FROM_ARCH=$(ssh -o ConnectTimeout=3 "$ARCH_USER@$ARCH_IP" "timeout 2 bash -c 'echo >/dev/tcp/$POPOS_IP/$REDIS_PORT' 2>/dev/null && echo 'ok' || echo 'fail'" 2>/dev/null)
  if [ "$REDIS_FROM_ARCH" = "ok" ]; then
    pass "Arch → Pop!_OS Redis ($POPOS_IP:$REDIS_PORT) reachable"
  else
    fail "Arch cannot reach Redis on $POPOS_IP:$REDIS_PORT"
  fi

else
  warn "SSH to Arch VM failed — skipping remote checks"
  info "Check: ssh $ARCH_USER@$ARCH_IP"
fi

# ═══════════════════════════════════════════════════════════════
# 8. BACKGROUND PROCESSES (Pop!_OS)
# ═══════════════════════════════════════════════════════════════
section "8/8" "Background processes (Pop!_OS)"

# Check metrics_receiver.py
MR_PID=$(pgrep -f "metrics_receiver" 2>/dev/null)
if [ -n "$MR_PID" ]; then
  pass "metrics_receiver.py is running (PID $MR_PID)"
else
  warn "metrics_receiver.py is NOT running"
  info "Start with: python3 ~/codex-workspace/codex-platform/scripts/metrics_receiver.py &"
fi

# Check sweep.py cron
SWEEP_CRON=$(crontab -l 2>/dev/null | grep "sweep.py")
if [ -n "$SWEEP_CRON" ]; then
  pass "sweep.py cron job exists"
  info "Cron: $SWEEP_CRON"
else
  warn "sweep.py cron job not found"
  info "Add with: (crontab -l; echo '0 * * * * cd $HOME/codex-workspace/codex-platform && python3 scripts/sweep.py') | crontab -"
fi

# Check Python packages
echo ""
info "Python packages:"
for pkg in paho-mqtt redis PyYAML; do
  VER=$(python3 -c "import importlib.metadata; print(importlib.metadata.version('$pkg'))" 2>/dev/null)
  if [ -n "$VER" ]; then
    pass "$pkg $VER"
  else
    fail "$pkg not installed"
  fi
done

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  SUMMARY${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "  ${GREEN}✓ Passed:  $PASS${NC}"
echo -e "  ${YELLOW}⚠ Warnings: $WARN${NC}"
echo -e "  ${RED}✗ Failed:  $FAIL${NC}"
echo ""

if [ $FAIL -eq 0 ] && [ $WARN -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}🟢 ALL SYSTEMS GO — ready for demo${NC}"
elif [ $FAIL -eq 0 ]; then
  echo -e "  ${YELLOW}${BOLD}🟡 MOSTLY READY — check warnings above${NC}"
else
  echo -e "  ${RED}${BOLD}🔴 ISSUES FOUND — fix failures before demo${NC}"
fi

echo ""

# ─── Quick-start commands if things are missing ───
if [ $WARN -gt 0 ] || [ $FAIL -gt 0 ]; then
  echo -e "${BOLD}  Quick-start commands:${NC}"
  echo ""
  echo "  # Pop!_OS — start the stack"
  echo "  cd ~/codex-workspace/codex-platform && docker compose up -d"
  echo ""
  echo "  # Pop!_OS — start metrics receiver"
  echo "  python3 ~/codex-workspace/codex-platform/scripts/metrics_receiver.py &"
  echo ""
  echo "  # Arch VM — start everything for demo"
  echo "  ssh $ARCH_USER@$ARCH_IP"
  echo "  bash   # if mysh is default shell"
  echo "  cd ~/codex-workspace/netlab && sudo ./lab/setup.sh"
  echo "  python3 ~/codex-workspace/codex-platform/syswatch_wrapper.py &"
  echo "  cd ~/codex-workspace/sentinel && sudo python3 src/main.py -i br-lab --no-dashboard"
  echo ""
  echo "  # Trigger demo"
  echo "  curl http://localhost:$N8N_PORT/webhook/red-team"
  echo ""
fi
