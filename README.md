# codex-platform

`codex-platform` is the orchestration layer for the codex security ecosystem. It connects independent tooling (sentinel, netlab, syswatch, and future IoT sources) into one observable pipeline using:

- Mosquitto (MQTT event bus)
- Redis (hot event store)
- n8n (workflow orchestration)
- Grafana (dashboards)
- SQLite (cold storage + threat intel)

The target demo flow is: trigger an attack, detect it, enrich it, route response actions, and visualize the full lifecycle in near real time.

## Architecture at a Glance

- Security tools run on an Arch VM (sensor side).
- Orchestration services run in Docker on Pop!_OS (control plane).
- Events move through MQTT topics (`codex/<source>/<event_type>`).
- Redis stores recent events for fast reads.
- SQLite stores long-term events and threat intelligence.
- n8n glues integrations (MQTT -> Discord/Redis/SQLite/SSH workflows).
- Grafana provides live and historical views.

Full design details and rationale are in `ARCHITECTURE.md`.

## Prerequisites

- Linux host with Docker Engine and Docker Compose plugin
- Python 3.10+ for local helper scripts
- `sqlite3` CLI available on host
- Network access between control-plane host and sensor host

Install quick check:

```bash
docker --version
docker compose version
python3 --version
sqlite3 --version
```

## Repository Layout

```text
codex-platform/
├── ARCHITECTURE.md
├── README.md
├── codex_bus.py
├── syswatch_wrapper.py
├── demo-start.sh
├── demo-stop.sh
├── healthcheck.sh
├── docker-compose.yml
├── soc-command-center-v2.json
├── topology-panel-v2.html
├── grafana-dashboards/
│   └── codex sec op-1774088358825.json
├── mosquitto/
│   ├── config/
│   ├── data/
│   └── log/
├── n8n-workflows/
│   ├── alert_triage_workflow.json
│   └── red-team-trigger-v2.json
├── scripts/
│   ├── load_intel.py
│   ├── metrics_receiver.py
│   └── sweep.py
├── sqlite/
│   └── schema.sql
└── threat-intel/
    └── intel.yaml
```

## Services and Ports

| Service | Purpose | Port |
|---|---|---|
| Mosquitto | MQTT broker (event transport) | `1883` |
| Redis | Hot event store/cache | `6379` |
| n8n | Workflow automation/orchestration | `5678` |
| Grafana | Dashboards and observability | `3000` |

## Quick Start

### 0. Create local env file

```bash
cp .env.example .env
```

Edit `.env` for your machine before running demo scripts. Common fields:
- `CODEX_COMPOSE_DIR`
- `CODEX_ARCH_WORKSPACE`
- `CODEX_ARCH_IP`, `CODEX_ARCH_USER`, `CODEX_POPOS_IP`
- `CODEX_MQTT_*`, `CODEX_REDIS_*`, `CODEX_N8N_PORT`, `CODEX_GRAFANA_*`

### 1. Start the stack

```bash
docker compose up -d
```

### 2. Check service health

```bash
docker compose ps
docker compose logs -f mosquitto redis n8n grafana
```

### 3. Initialize SQLite schema

```bash
sqlite3 sqlite/codex.db < sqlite/schema.sql
```

### 4. Load threat intelligence from YAML

```bash
python3 scripts/load_intel.py
```

### 5. Run the metrics receiver (optional, for syswatch feed)

```bash
python3 scripts/metrics_receiver.py
```

### 6. Sweep Redis alerts to SQLite (manual run)

```bash
python3 scripts/sweep.py
```

### 7. Access UIs

- n8n: `http://localhost:5678`
- Grafana: `http://localhost:3000` (default configured user/password in compose)

## Troubleshooting

### Docker services fail to start

```bash
docker compose ps
docker compose logs --tail=100 mosquitto redis n8n grafana
```

If a service is unhealthy, check port conflicts and credentials in `.env`.

### MQTT auth/healthcheck failures

- Verify `CODEX_MQTT_USER` and `CODEX_MQTT_PASS` in `.env`
- Confirm `mosquitto/config/passwd` exists and matches configured credentials

### Redis auth failures

- Verify `CODEX_REDIS_PASS` in `.env`
- Confirm the same value is used by scripts and container health checks

### SQLite path issues

- Ensure `CODEX_SQLITE_DB` points to a writable path
- Recreate schema if needed:

```bash
sqlite3 sqlite/codex.db < sqlite/schema.sql
```

## Imported Assets

- Grafana dashboard export: `grafana-dashboards/codex sec op-1774088358825.json`
- Grafana dashboard (SOC v2): `soc-command-center-v2.json`
- Grafana HTML topology panel snippet: `topology-panel-v2.html`
- n8n alert workflow export: `n8n-workflows/alert_triage_workflow.json`
- n8n red-team trigger workflow export: `n8n-workflows/red-team-trigger-v2.json`

## Event Topics

Current topic design:

- `codex/sentinel/alerts`
- `codex/sentinel/iot-alerts` (planned)
- `codex/netlab/attacks`
- `codex/syswatch/metrics`
- `codex/platform/heartbeat`
- `codex/platform/commands`

Conventions:

- Keep topics stable and semantic (`source` + `event_type`).
- Put variable values (IP, timestamp, IDs) in payload, not topic names.
- Use wildcard subscriptions in n8n where needed (for example `codex/sentinel/#`).

## Data Model

`sqlite/schema.sql` defines two core tables:

- `events`: historical archived events (timestamp, source, severity, payload, enrichment flag)
- `metrics`: syswatch time-series metrics used by Grafana panels
- `threat_intel`: curated lookup data used to enrich detections

`threat-intel/intel.yaml` is the source of truth for attack metadata and is loaded into SQLite by `scripts/load_intel.py`.

## Operating Notes

- Redis is used as hot storage; SQLite is used as cold storage.
- n8n workflows should handle routing and sequencing, while enrichment logic stays in code (for example in sentinel).
- Architecture choices, tradeoffs, and phase gates are documented in `ARCHITECTURE.md`.

## Security Notes

- Never commit a real `.env`; use `.env.example` as template only.
- Rotate all credentials before any public deployment.
- Keep runtime state directories (`grafana-data/`, `n8n-data/`, `redis-data/`, `logs/`) out of version control.

## License

License file is not finalized yet. Add `LICENSE` before public publishing.

## Roadmap (Phased)

- Phase 1: Bus foundation (MQTT + Redis, first event flow)
- Phase 2: Orchestration brain (n8n + enrichment + Discord)
- Phase 3: Visibility layer (Grafana + history views)
- Phase 4: One-button red-team lifecycle demo
- Phase 5: IoT extension via Wokwi and ESP32 traffic

Detailed proofs-of-life and risk mitigations are in `ARCHITECTURE.md`.
