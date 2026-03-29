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


def _load_dotenv(path: str) -> None:
    if not os.path.isfile(path):
        return
    with open(path, "r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value


_load_dotenv(os.path.join(PLATFORM_DIR, ".env"))


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == '':
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


REDIS_HOST = _required_env('CODEX_LOCAL_HOST')
REDIS_PORT = int(_required_env('CODEX_REDIS_PORT'))
REDIS_PASS = _required_env('CODEX_REDIS_PASS')

STREAMS = [
    ('stream:codex/sentinel/alerts', 'codex/sentinel/alerts', 'sentinel'),
    ('stream:codex/netlab/alerts',   'codex/netlab/alerts',   'netlab'),
    ('stream:codex/syswatch/alerts', 'codex/syswatch/alerts', 'syswatch'),
]

def get_redis():
    return redis.Redis(host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASS, decode_responses=True)

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