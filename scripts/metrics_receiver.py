#!/usr/bin/env python3
"""Subscribe to syswatch metrics via MQTT and write to SQLite."""
import json
import sqlite3
import os
import paho.mqtt.client as mqtt

PLATFORM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(PLATFORM_DIR, "sqlite", "codex.db")


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
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


MQTT_HOST = _required_env("CODEX_LOCAL_HOST")
MQTT_PORT = int(_required_env("CODEX_MQTT_PORT"))
MQTT_USER = _required_env("CODEX_MQTT_USER")
MQTT_PASS = _required_env("CODEX_MQTT_PASS")

def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload.decode())
        data = payload.get('data', {})
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.execute(
            'INSERT INTO metrics (timestamp, cpu_percent, mem_percent, mem_used_mb, disk_percent, net_rx_bytes_sec, net_tx_bytes_sec) VALUES (?, ?, ?, ?, ?, ?, ?)',
            (
                payload.get('timestamp', ''),
                data.get('cpu_percent', 0),
                data.get('mem_percent', 0),
                data.get('mem_used_mb', 0),
                data.get('disk_percent', 0),
                data.get('net_rx_bytes_sec', 0),
                data.get('net_tx_bytes_sec', 0),
            )
        )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f'[metrics_receiver] Error: {e}')

def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_message = on_message
    client.username_pw_set(MQTT_USER, MQTT_PASS)
    client.connect(MQTT_HOST, MQTT_PORT)
    client.subscribe('codex/syswatch/metrics')
    print('[metrics_receiver] Listening for syswatch metrics. Ctrl+C to stop.')
    try:
        client.loop_forever()
    except KeyboardInterrupt:
        print('\n[metrics_receiver] Stopped.')
        client.disconnect()

if __name__ == '__main__':
    main()
