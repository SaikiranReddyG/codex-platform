#!/usr/bin/env python3
"""Subscribe to syswatch metrics via MQTT and write to SQLite."""
import json
import sqlite3
import os
import paho.mqtt.client as mqtt

PLATFORM_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DB_PATH = os.path.join(PLATFORM_DIR, "sqlite", "codex.db")

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
    client.username_pw_set('codex', 'codex-mqtt-2026')
    client.connect('localhost', 1883)
    client.subscribe('codex/syswatch/metrics')
    print('[metrics_receiver] Listening for syswatch metrics. Ctrl+C to stop.')
    try:
        client.loop_forever()
    except KeyboardInterrupt:
        print('\n[metrics_receiver] Stopped.')
        client.disconnect()

if __name__ == '__main__':
    main()
