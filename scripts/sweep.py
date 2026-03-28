#!/usr/bin/env python3
"""Sweep events from Redis to SQLite. Runs continuously every 30s."""
import redis
import sqlite3
import json
import os
import time

PLATFORM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(PLATFORM_DIR, "sqlite", "codex.db")
INTERVAL = 30  # seconds

STREAMS = [
    ('stream:codex/sentinel/alerts', 'codex/sentinel/alerts', 'sentinel'),
    ('stream:codex/netlab/alerts',   'codex/netlab/alerts',   'netlab'),
    ('stream:codex/syswatch/alerts', 'codex/syswatch/alerts', 'syswatch'),
]

def get_redis():
    return redis.Redis(host='localhost', port=6379, password='codex-redis-2026', decode_responses=True)

def sweep(r, conn):
    cursor = conn.cursor()
    total_new = 0

    for stream_key, mqtt_topic, default_source in STREAMS:
        try:
            entries = r.xrange(stream_key)
        except Exception as e:
            print(f"[sweep] Could not read {stream_key}: {e}")
            continue

        new = 0
        for entry_id, fields in entries:
            try:
                data = json.loads(fields.get('data', '{}'))
            except json.JSONDecodeError:
                continue

            timestamp = data.get('timestamp', '')
            source = data.get('source', default_source)

            cursor.execute(
                'SELECT COUNT(*) FROM events WHERE timestamp = ? AND source = ?',
                (timestamp, source)
            )
            if cursor.fetchone()[0] > 0:
                continue

            severity = data.get('data', {}).get('severity', data.get('severity', 'medium'))
            event_type = data.get('type', 'alert')

            cursor.execute(
                'INSERT INTO events (timestamp, source, event_type, severity, mqtt_topic, payload, enriched) '
                'VALUES (?, ?, ?, ?, ?, ?, ?)',
                (timestamp, source, event_type, severity, mqtt_topic, json.dumps(data), 0)
            )
            new += 1

        if new:
            print(f"[sweep] {stream_key}: +{new} new events")
        total_new += new

    conn.commit()
    return total_new

def main():
    print(f"[sweep] Starting — polling every {INTERVAL}s. Ctrl+C to stop.")
    while True:
        try:
            r = get_redis()
            conn = sqlite3.connect(DB_PATH, timeout=5)
            count = sweep(r, conn)
            conn.close()
            if count:
                print(f"[sweep] Total this run: {count} new events")
        except Exception as e:
            print(f"[sweep] Error: {e}")
        time.sleep(INTERVAL)

if __name__ == '__main__':
    main()