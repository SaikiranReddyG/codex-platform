# CODEX-WORKSPACE — Platform Architecture

> The blueprint for integrating all codex-workspace projects into a unified security operations platform.
> Produced from architecture discussion — 2026-03-19
> This document captures every decision, the reasoning behind it, and known risks.

---

## EXECUTIVE SUMMARY

The codex-workspace projects (sentinel, netlab, syswatch, mysh, breakbin, firmhack) are being integrated into a cohesive security operations platform. The platform adds an orchestration layer (n8n), a message bus (MQTT + Redis), and a visualization layer (Grafana) — turning six independent projects into a demonstrable end-to-end security pipeline.

The north star goal: **one button triggers an attack, sentinel detects it, the pipeline enriches and responds, and the entire lifecycle is visible on a single dashboard in real time.**

---

## ARCHITECTURE OVERVIEW

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        POP!_OS (Orchestration Host)                     │
│                        AMD Ryzen 5 5600H · 16GB RAM                     │
│                                                                         │
│   ┌─── Docker Compose ────────────────────────────────────────────┐     │
│   │                                                                │     │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │     │
│   │   │Mosquitto │  │  Redis   │  │   n8n    │  │ Grafana  │    │     │
│   │   │  (MQTT)  │  │ (cache + │  │ (glue + │  │  (live   │    │     │
│   │   │  :1883   │  │  hot     │  │  orches- │  │  dash-   │    │     │
│   │   │          │  │  store)  │  │  tration)│  │  boards) │    │     │
│   │   │          │  │  :6379   │  │  :5678   │  │  :3000   │    │     │
│   │   └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘    │     │
│   │        │              │              │              │          │     │
│   └────────┼──────────────┼──────────────┼──────────────┼──────────┘     │
│            │              │              │              │                 │
│   ┌────────┴──────────────┴──────────────┴──────────────┘                │
│   │                    Local Network (static IPs)                        │
│   └────────┬─────────────────────────────────────────────────────────────┘
│            │
│            │  MQTT publish / SSH commands
│            │
│   ┌────────┴─────────────────────────────────────────────────────────────┐
│   │                     ARCH VM (Sensor Platform)                        │
│   │                   4GB RAM · 40GB disk · Bridged                      │
│   │                                                                      │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
│   │   │ sentinel │  │  netlab  │  │ syswatch │  │  mysh    │           │
│   │   │  (IDS)   │  │ (attack/ │  │ (system  │  │ (shell)  │           │
│   │   │          │  │  defense │  │  monitor) │  │          │           │
│   │   │ Python   │  │  lab)    │  │  C + py  │  │  C       │           │
│   │   │          │  │ Bash+Py  │  │  wrapper  │  │          │           │
│   │   └──────────┘  └──────────┘  └──────────┘  └──────────┘           │
│   │                                                                      │
│   │   ┌──────────┐  ┌──────────┐                                        │
│   │   │ breakbin │  │ firmhack │  (future — no pipeline changes needed) │
│   │   │  (CTF)   │  │ (RE/IoT) │                                        │
│   │   └──────────┘  └──────────┘                                        │
│   │                                                                      │
│   └──────────────────────────────────────────────────────────────────────┘
│
│   ┌──────────────────────────────────────────────────────────────────────┐
│   │                     WOKWI (Future — Phase 5)                         │
│   │              ESP32 simulation → IoT traffic → sentinel               │
│   └──────────────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────────┘
```

---

## DECISIONS LOG

Every architectural decision made, with reasoning.

### 1. Where services run
**Decision:** Pop!_OS hosts all orchestration (Docker). Arch VM hosts all security tools.
**Reasoning:** Arch VM has limited RAM (4GB), security tools need raw access to interfaces/namespaces//proc. Pop!_OS is stable, always-on, and has resources for Docker containers. This mirrors real SOC architecture — sensors deployed on endpoints, SOAR platform centralized.

### 2. Communication layer
**Decision:** MQTT (Mosquitto) for real-time event transport + Redis for persistence and history.
**Reasoning:** MQTT is the native IoT protocol — using it directly supports the OT/IoT career angle for Bosch/Honeywell roles. Redis provides event history and replay that MQTT alone can't. Together they mirror how real OT security monitoring platforms work. Both are lightweight Docker containers (~7MB combined RAM).

### 3. Network configuration
**Decision:** Static IPs on both machines. Home network only, no port exposure concerns.
**Reasoning:** DHCP lease changes would silently break MQTT/SSH connections between machines. Static IPs eliminate this class of failure entirely. Since the laptop never leaves home, no need for firewall hardening on exposed ports (Mosquitto 1883, Redis 6379, n8n 5678, Grafana 3000). Platform security hardening (auth, credentials) deferred to polish phase before publishing.

### 4. Event data format
**Decision:** Tool-native formats initially. Evolve toward a common envelope after observing real data patterns.
**Reasoning:** Designing a common schema before understanding the data leads to either constant reshaping or meaningless generic wrappers. Each tool emits whatever JSON is natural. MQTT topics separate event sources. n8n builds lightweight normalizers as patterns emerge. Common envelope extracted from experience, not theory. Follows the "capture fast, structure later" principle (same as IDEAS.md workflow).

### 5. Logic ownership
**Decision:** n8n is glue only. Smart logic (detection, enrichment, classification) stays in Python.
**Reasoning:** Portfolio credibility requires visible, version-controlled, testable code — not JavaScript snippets inside n8n function nodes. Sentinel does its own enrichment from YAML/SQLite before publishing. n8n handles routing, sequencing, and integration (MQTT → Discord, MQTT → Redis, SSH triggers). An interviewer sees n8n for the flow, GitHub repos for the engineering.

### 6. Threat intelligence
**Decision:** YAML file as hand-curated source of truth → loaded into SQLite as queryable store.
**Reasoning:** YAML is easy to edit, version control, and review. SQLite is queryable by n8n (native node) and Grafana (native datasource). Sentinel reads SQLite during enrichment. MITRE ATT&CK technique IDs can be added as YAML fields later without structural changes. No fake VirusTotal lookups on private lab IPs — local intel is honest and functional.

### 7. Data retention
**Decision:** Redis for hot data (last 24-48 hours). SQLite for cold data (weekly+). n8n sweeps Redis → SQLite nightly.
**Reasoning:** Redis in-memory speed powers Grafana's real-time panels. SQLite file-based storage handles historical queries efficiently at this scale. A week of events in SQLite is trivially small (<10MB). The hot/cold split is a real-world pattern that demonstrates infrastructure thinking.

### 8. Alerting
**Decision:** Discord. Reuse the server already being built for Nanobot/LM Studio.
**Reasoning:** One Discord server, multiple channels (#alerts, #red-team, #system-health). n8n has a native Discord node. Rich embeds with color-coded severity look great in portfolio screenshots. Already planning Discord presence for the AI bot — single notification surface.

### 9. Autonomy level
**Decision:** Start fully autonomous. Add severity-based human-in-the-loop tiers later.
**Reasoning:** Get the end-to-end loop working first. Adding tiered response (low=auto, high=wait for Discord approval) is a refinement that shows growth in thinking: "I started autonomous, then realized that's not how real OT environments work." n8n's Wait node supports pausing workflows for human input when ready.

### 10. Infrastructure management
**Decision:** Docker Compose. One file, one command, entire orchestration stack up.
**Reasoning:** Reproducibility and portfolio credibility. Someone clones the repo, runs `docker compose up`, and has the exact same setup. n8n workflows exported as JSON, Grafana dashboards exported as JSON — entire platform is infrastructure-as-code in a Git repo. Demonstrates DevOps skills relevant to target employers.

### 11. Repository structure
**Decision:** Keep existing separate repos. Add new `codex-platform` orchestration repo.
**Reasoning:** Individual projects (sentinel, mysh, syswatch) are portfolio pieces on their own, each telling an independent story. The new `codex-platform` repo is the capstone — docker-compose.yml, n8n workflows, Grafana dashboards, threat intel YAML, SQLite schema, architecture docs. An interviewer looks at individual repos for depth, platform repo for breadth.

```
GitHub (github.com/SaikiranReddyG):
├── mysh              (unchanged — standalone C project)
├── syswatch          (add: Python MQTT wrapper)
├── sentinel          (add: MQTT publishing, enrichment, Redis dual-write)
├── netlab            (add: event emission, remote trigger entry point)
├── breakbin          (unchanged for now)
├── firmhack          (unchanged for now)
├── codex-arch        (unchanged — Arch blueprint)
├── wokwi-lab         (existing tinkering repo — future Phase 5)
└── codex-platform    (NEW — orchestration layer)
    ├── docker-compose.yml
    ├── n8n-workflows/
    ├── grafana-dashboards/
    ├── threat-intel/
    │   ├── intel.yaml
    │   └── load_intel.py
    ├── sqlite/
    │   └── schema.sql
    ├── configs/
    │   ├── mosquitto.conf
    │   └── redis.conf
    ├── ARCHITECTURE.md (this document)
    └── README.md
```

### 12. Visualization
**Decision:** Grafana for live operational dashboards + n8n canvas for workflow logic visualization.
**Reasoning:** Grafana shows "what's happening now" — time-series metrics, alert panels, system health. n8n canvas shows "how it all connects" — the visual workflow is the architecture diagram. Together they serve all three audiences: interview demos (Grafana live), portfolio screenshots (both), daily lab monitoring (Grafana).

### 13. Failure protections
**Decision:** Dual write (MQTT + Redis) and rate limiting built in from the start. Heartbeat monitoring and SSH error handling added later.
**Reasoning:** Lost events and alert floods are the two failures that would undermine the system's credibility. Dual write ensures events persist even if n8n misses them. Rate limiting (aggregate events over a 5-second window in n8n) prevents alert fatigue during aggressive attacks. Heartbeat and SSH error handling are operational polish — important but not foundational.

### 14. Syswatch MQTT approach
**Decision:** Python wrapper that reads syswatch output and publishes to MQTT.
**Reasoning:** Faster to build than adding libmosquitto to C code. Gets syswatch into the pipeline without rewriting the tool. Can be replaced with native C MQTT integration later for portfolio points.

---

## MQTT TOPIC STRUCTURE

```
codex/{source}/{event_type}

codex/sentinel/alerts        ← security detections from sentinel
codex/sentinel/iot-alerts    ← IoT-specific detections (Phase 5, Wokwi)
codex/netlab/attacks         ← attack lifecycle events (start/stop/result)
codex/syswatch/metrics       ← system metrics (CPU, memory, disk, network)
codex/platform/heartbeat     ← system health pings
codex/platform/commands      ← red team trigger commands (n8n → Arch)
```

**Conventions:**
- Three levels: `codex/{who's talking}/{what they're saying}`
- Never put variable data in topic names (IPs, timestamps go in payload)
- n8n subscribes using wildcards: `codex/sentinel/#` catches all sentinel events, `codex/+/alerts` catches alerts from any source

---

## DATA FLOW — ALERT TRIAGE PIPELINE

```
ARCH VM                                           POP!_OS
────────                                          ────────

 hping3/nmap                                      
     │                                            
     ▼                                            
 sentinel                                         
 (detect → enrich from SQLite → classify)         
     │                                            
     ├──── MQTT publish ──────────────────────▶  Mosquitto (:1883)
     │     topic: codex/sentinel/alerts                │
     │                                                 │
     └──── Redis dual-write ──────────────────▶  Redis (:6379)
           (backup — event persists                    │
            even if n8n is down)                       │
                                                       ▼
                                                  n8n (:5678)
                                                  MQTT trigger node
                                                       │
                                              ┌────────┼────────┐
                                              │        │        │
                                              ▼        ▼        ▼
                                           Discord   Redis    SQLite
                                           alert     store    archive
                                           (rich     (hot     (cold
                                           embed)    24-48h)  weekly)
                                                       │
                                                       ▼
                                                  Grafana (:3000)
                                                  live dashboard
```

---

## DATA FLOW — RED TEAM AUTOMATION (North Star)

```
YOU (click one button)
     │
     ▼
n8n webhook / Discord command
     │
     ▼
n8n Red Team Workflow
     │
     ├──── SSH into Arch VM ─────────────────▶  netlab
     │     run: python run_attack.py arp_spoof        │
     │                                                 │
     │     ◀── MQTT ─────────────────────────── netlab publishes
     │         codex/netlab/attacks                    attack_start event
     │         {"attack": "arp_spoof",                 │
     │          "status": "started"}                   ▼
     │                                            sentinel detects
     │     ◀── MQTT ─────────────────────────── sentinel publishes
     │         codex/sentinel/alerts                   enriched alert
     │                                                 │
     ▼                                                 │
n8n processes alert                                    │
     │                                                 │
     ├──── Discord: "Attack detected + enriched"       │
     ├──── Redis: store event (hot)                    │
     ├──── SQLite: archive (cold)                      │
     └──── (Future) SSH mitigation command ───▶  Arch: block IP
                                                       │
                                                       ▼
                                                  Grafana shows
                                                  entire lifecycle
                                                  in real time
```

---

## WOKWI / IoT INTEGRATION (Phase 5)

```
Wokwi (VS Code extension)
     │
     ▼
ESP32 Simulation
(unencrypted MQTT, hardcoded creds, insecure protocols)
     │
     ├──── Phase 5A: PCAP export → replay through sentinel (offline)
     │
     └──── Phase 5B: Private Gateway → live traffic on local network
                │
                ▼
           sentinel on Arch
           (detects IoT-specific anomalies)
                │
                ▼
           Same pipeline as above
           (MQTT → n8n → enrich → alert → Grafana)

GRAFANA IoT DASHBOARD:
┌─────────────────────────────────────────────────┐
│  Top row:    ESP32 telemetry (temp, humidity)    │ ← normal IoT ops
│  Middle row: Network health, MQTT message rates  │ ← infrastructure
│  Bottom row: Security alerts from sentinel       │ ← attack impact
│              (IoT anomaly lights up here while   │
│               top row shows device affected)     │
└─────────────────────────────────────────────────┘
```

---

## IMPLEMENTATION PHASES

### Phase 1: THE BUS
**Goal:** Events flow from Arch to Pop!_OS and are stored.

**Build:**
- [ ] Set static IPs on Pop!_OS and Arch VM
- [ ] Create `codex-platform` repo with docker-compose.yml (Mosquitto + Redis)
- [ ] `docker compose up` — verify both services running
- [ ] Add MQTT publishing to sentinel (one alert type)
- [ ] Add Redis dual-write to sentinel
- [ ] Write simple Python subscriber on Pop!_OS to verify events arrive

**Proof of life:** Run sentinel on Arch, trigger a detection with nmap or hping3. On Pop!_OS, run `redis-cli` and see the alert stored. Event created on Arch → stored on Pop!_OS. No n8n, no Grafana, no fancy anything.

**Dependencies:** None — this is the foundation.

---

### Phase 2: THE BRAIN
**Goal:** n8n receives events, enriches them, and acts.

**Build:**
- [ ] Add n8n to docker-compose.yml
- [ ] Create YAML threat intel file (map attack types → severity, CVE, description)
- [ ] Write `load_intel.py` to load YAML into SQLite
- [ ] Move sentinel's enrichment to read from SQLite
- [ ] Build n8n workflow: MQTT trigger → Discord alert → Redis write
- [ ] Set up Discord server with #alerts channel
- [ ] Configure n8n Discord node

**Proof of life:** Trigger a detection on Arch. Within seconds, a formatted Discord message appears with enriched context (attack name, severity, description). You touched nothing between detection and notification.

**Dependencies:** Phase 1 complete.

---

### Phase 3: THE EYES
**Goal:** Grafana shows live state and historical patterns.

**Build:**
- [ ] Add Grafana to docker-compose.yml
- [ ] Configure Grafana datasources (Redis, SQLite)
- [ ] Build dashboard: live alerts panel (Redis), alert history panel (SQLite)
- [ ] Write syswatch Python MQTT wrapper
- [ ] Add syswatch metrics panel to Grafana
- [ ] Build n8n hot-to-cold sweep workflow (Redis → SQLite nightly)

**Proof of life:** Open Grafana. See live CPU/memory from syswatch updating in real time. Trigger an attack — alert appears on the same dashboard. Switch to "last 7 days" view — historical events from SQLite visible.

**Dependencies:** Phase 2 complete.

---

### Phase 4: THE SHOW
**Goal:** One-button red team demo works end to end.

**Build:**
- [ ] Add remote trigger to netlab: `python run_attack.py <attack_name>`
- [ ] Add MQTT event emission to netlab (attack start/stop)
- [ ] Build n8n red team workflow: webhook → SSH → attack → wait for alert → process → alert
- [ ] Add rate limiting to n8n (5-second aggregation window for event floods)
- [ ] Add netlab attack lifecycle panels to Grafana
- [ ] Test full cycle: one button → attack → detect → enrich → mitigate → alert → dashboard

**Proof of life:** Click one button. Without touching anything else: attack runs, gets detected, gets enriched, Discord notification arrives, Grafana shows the entire event timeline. You narrate it to someone and they understand what happened.

**Dependencies:** Phase 3 complete. Sentinel and netlab migrated to Arch.

---

### Phase 5: THE IoT ANGLE
**Goal:** ESP32 traffic monitored and triaged through the same pipeline.

**Build:**
- [ ] Phase 5A: Build vulnerable ESP32 simulation in Wokwi, export PCAPs, replay through sentinel, write IoT detection rules
- [ ] Phase 5B: Configure Wokwi Private Gateway for live traffic routing
- [ ] Add IoT-specific entries to threat intel YAML
- [ ] Add sentinel rules for IoT anomalies (unencrypted MQTT, default creds)
- [ ] Build Grafana IoT dashboard (telemetry + security on same screen)
- [ ] n8n workflow for IoT-specific alert handling

**Proof of life:** Grafana shows ESP32 sensor telemetry streaming live. Trigger an IoT attack. Security panel lights up showing the anomaly while the telemetry panel shows the impact on the device. Same pipeline, new attack surface.

**Dependencies:** Phase 4 complete. Wokwi gateway configured.

---

## KNOWN RISKS AND MITIGATIONS

### Risk: Events lost during n8n restart
**Mitigation:** Dual write — sentinel publishes to MQTT AND writes directly to Redis. If n8n misses an MQTT message, the event is still in Redis for Grafana and report generation.

### Risk: Alert flood from aggressive attacks
**Mitigation:** Rate limiting in n8n — aggregate events over a 5-second window, process as one "attack burst" rather than hundreds of individual alerts. Prevents Discord spam and n8n overload.

### Risk: VM IP changes breaking connections
**Mitigation:** Static IPs on both machines. Configured once, never changes.

### Risk: Docker Compose configuration drift
**Mitigation:** All Docker configs, n8n workflow exports, and Grafana dashboard exports version-controlled in `codex-platform` repo. Rebuild from scratch with one `docker compose up`.

### Risk: Sentinel event format changes breaking n8n
**Mitigation:** Tool-native formats with n8n normalizers. Changes in sentinel don't require n8n changes unless the normalizer needs updating. Common envelope evolved later from observed patterns.

### Risk: SQLite concurrent access issues
**Mitigation:** At this scale (few events per minute), SQLite handles concurrent reads fine. Only one writer (n8n sweep job or sentinel enrichment) at a time. WAL mode enabled for better concurrency.

### Risk: Scope creep from new ideas mid-build
**Mitigation:** IDEAS.md captures new ideas. This document defines phases with clear proof-of-life criteria. A phase is "done" when its proof of life passes. New ideas go to IDEAS.md, not into the current phase.

---

## FUTURE ADDITIONS (Not in current phases)

These are captured here so they don't get lost but don't derail current work.

- **Severity-tiered human-in-the-loop:** Discord reaction buttons for approve/deny on high-severity alerts. n8n Wait node pauses workflow until human responds.
- **LM Studio report generation:** End-of-day batch summary through local LLM. Only valuable when there's enough event history to summarize (Phase 3+).
- **MITRE ATT&CK mapping:** Add technique IDs to threat intel YAML entries. Enrichment output includes MITRE tactic/technique for each alert.
- **Uptime Kuma:** Lightweight status page showing all services (sentinel, n8n, Grafana, Redis, Mosquitto). Nice for portfolio.
- **Syswatch C MQTT rewrite:** Replace Python wrapper with native libmosquitto integration in syswatch for deeper systems skill demonstration.
- **Breakbin event emission:** CTF challenges emit completion events to MQTT when exploited. n8n tracks progress.
- **Portfolio site:** Showcase everything with architecture diagrams, Grafana screenshots, n8n workflow exports, and project writeups.
- **Platform security hardening:** Mosquitto authentication, Redis password, n8n credentials, Grafana auth. Do before publishing configs to public GitHub.

---

## TOOL REFERENCE

| Tool | Role | Runs on | Port | Docker |
|------|------|---------|------|--------|
| Mosquitto | MQTT broker (real-time event bus) | Pop!_OS | 1883 | Yes |
| Redis | Hot event store + cache | Pop!_OS | 6379 | Yes |
| n8n | Workflow orchestration (glue) | Pop!_OS | 5678 | Yes |
| Grafana | Live dashboards | Pop!_OS | 3000 | Yes |
| sentinel | Network IDS | Arch VM | — | No |
| netlab | Attack/defense lab | Arch VM | — | No |
| syswatch | System monitor | Arch VM | — | No |
| mysh | Custom shell | Arch VM | — | No |
| SQLite | Cold event store + threat intel | Pop!_OS | — | File |
| Discord | Alert notifications | Cloud | — | — |

---

## PREREQUISITES BEFORE PHASE 1

These must be true before starting Phase 1:

- [x] sentinel migrated to Arch and functional (from ECOSYSTEM-MAP next steps #1)
- [x] netlab migrated to Arch and functional (from ECOSYSTEM-MAP next steps #2)
- [x] Docker and Docker Compose installed on Pop!_OS
- [x] Static IPs configured on both machines
- [x] `codex-platform` repo initialized on GitHub
- [x] Discord server created with #alerts channel
