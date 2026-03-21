-- ============================================================================
-- CODEX-PLATFORM SQLite Schema
-- ============================================================================
-- Cold storage for events + threat intelligence lookup table.
-- Created by: install-popos.sh
-- ============================================================================

-- Event archive (cold storage, swept from Redis by n8n nightly)
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,           -- ISO 8601
    source TEXT NOT NULL,              -- sentinel, netlab, syswatch
    event_type TEXT NOT NULL,          -- alert, attack, metric
    severity TEXT DEFAULT 'info',      -- info, low, medium, high, critical
    mqtt_topic TEXT,                   -- original MQTT topic
    payload TEXT NOT NULL,             -- full JSON payload
    enriched INTEGER DEFAULT 0,        -- 0 = raw, 1 = enriched
    created_at TEXT DEFAULT (datetime('now'))
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
CREATE INDEX IF NOT EXISTS idx_events_source ON events(source);
CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(event_type);

-- Threat intelligence (loaded from YAML by load_intel.py)
CREATE TABLE IF NOT EXISTS threat_intel (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    attack_type TEXT UNIQUE NOT NULL,  -- syn_flood, arp_spoof, buffer_overflow
    display_name TEXT NOT NULL,        -- SYN Flood Attack
    description TEXT,                  -- Human-readable description
    severity TEXT NOT NULL,            -- low, medium, high, critical
    cve_ids TEXT,                      -- comma-separated CVE IDs (if applicable)
    mitre_technique TEXT,              -- MITRE ATT&CK technique ID (future)
    mitre_tactic TEXT,                 -- MITRE ATT&CK tactic (future)
    response_action TEXT DEFAULT 'log', -- log, alert, mitigate
    notes TEXT,                        -- additional context
    updated_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_intel_attack_type ON threat_intel(attack_type);
