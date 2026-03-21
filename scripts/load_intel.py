#!/usr/bin/env python3
"""
Load threat intelligence from YAML into SQLite.
Run after editing threat-intel/intel.yaml to update the database.

Usage:
    python3 scripts/load_intel.py
"""

import yaml
import sqlite3
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PLATFORM_DIR = os.path.dirname(SCRIPT_DIR)
YAML_PATH = os.path.join(PLATFORM_DIR, "threat-intel", "intel.yaml")
DB_PATH = os.path.join(PLATFORM_DIR, "sqlite", "codex.db")

def load():
    with open(YAML_PATH, "r") as f:
        data = yaml.safe_load(f)

    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()

    loaded = 0
    for attack in data.get("attacks", []):
        cursor.execute("""
            INSERT OR REPLACE INTO threat_intel
            (attack_type, display_name, description, severity, cve_ids,
             mitre_technique, mitre_tactic, response_action, notes, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
        """, (
            attack["attack_type"],
            attack["display_name"],
            attack.get("description", ""),
            attack["severity"],
            attack.get("cve_ids", ""),
            attack.get("mitre_technique", ""),
            attack.get("mitre_tactic", ""),
            attack.get("response_action", "log"),
            attack.get("notes", ""),
        ))
        loaded += 1

    conn.commit()
    conn.close()
    print(f"[OK] Loaded {loaded} threat intel entries into {DB_PATH}")

if __name__ == "__main__":
    load()
