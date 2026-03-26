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

## Roadmap (Phased)

- Phase 1: Bus foundation (MQTT + Redis, first event flow)
- Phase 2: Orchestration brain (n8n + enrichment + Discord)
- Phase 3: Visibility layer (Grafana + history views)
- Phase 4: One-button red-team lifecycle demo
- Phase 5: IoT extension via Wokwi and ESP32 traffic

Detailed proofs-of-life and risk mitigations are in `ARCHITECTURE.md`.
