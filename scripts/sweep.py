#!/usr/bin/env python3
"""Sweep events from Redis to SQLite. Run via cron hourly."""
import redis
import sqlite3
import json
import os

PLATFORM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(PLATFORM_DIR, "sqlite", "codex.db")

r = redis.Redis(host='localhost', port=6379, password='codex-redis-2026', decode_responses=True)
conn = sqlite3.connect(DB_PATH, timeout=5)
cursor = conn.cursor()

entries = r.xrange('stream:codex/sentinel/alerts')
count = 0

for entry_id, fields in entries:
    data = json.loads(fields.get('data', '{}'))
    timestamp = data.get('timestamp', '')
    
    cursor.execute('SELECT COUNT(*) FROM events WHERE timestamp = ? AND source = ?',
                   (timestamp, data.get('source', 'sentinel')))
    if cursor.fetchone()[0] > 0:
        continue
    
    cursor.execute(
        'INSERT INTO events (timestamp, source, event_type, severity, mqtt_topic, payload, enriched) VALUES (?, ?, ?, ?, ?, ?, ?)',
        (timestamp, data.get('source', 'sentinel'), data.get('type', 'alert'),
         data.get('data', {}).get('severity', 'medium'), 'codex/sentinel/alerts',
         json.dumps(data), 0))
    count += 1

conn.commit()
conn.close()
print(f"[sweep] {count} new events written to SQLite ({len(entries)} total in stream)")
