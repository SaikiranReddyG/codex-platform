#!/usr/bin/env python3
"""
codex_bus.py — Shared MQTT + Redis publishing module for codex-workspace projects.

Usage in sentinel:
    from codex_bus import CodexBus
    bus = CodexBus()
    bus.publish_alert({
        "source_ip": "10.0.0.2",
        "attack_type": "syn_flood",
        "details": "High SYN rate detected"
    })

Usage in netlab:
    from codex_bus import CodexBus
    bus = CodexBus()
    bus.publish_attack_event("arp_spoof", "started")

Usage in syswatch wrapper:
    from codex_bus import CodexBus
    bus = CodexBus()
    bus.publish_metrics({"cpu": 45.2, "memory": 62.1, "disk": 78.0})

Environment variables (override defaults):
    CODEX_POPOS_IP   — Pop!_OS IP address (default: 192.168.1.50)
    CODEX_MQTT_PORT  — Mosquitto port (default: 1883)
    CODEX_REDIS_PORT — Redis port (default: 6379)
"""

import json
import os
import time
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
import redis as redis_lib


class CodexBus:
    """Publish events to the codex-platform MQTT broker and Redis store."""

    def __init__(self, source: str = "unknown"):
        """
        Args:
            source: Name of the publishing tool (sentinel, netlab, syswatch)
        """
        self.source = source
        self.popos_ip = os.environ.get("CODEX_POPOS_IP", "192.168.1.50")
        self.mqtt_port = int(os.environ.get("CODEX_MQTT_PORT", "1883"))
        self.redis_port = int(os.environ.get("CODEX_REDIS_PORT", "6379"))

        # MQTT client (paho-mqtt v2.x with VERSION2 callbacks)
        self._mqtt = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        self._mqtt_connected = False

        # Redis client (for dual-write)
        self._redis = None

    def connect(self):
        """Connect to MQTT broker and Redis on Pop!_OS."""
        # MQTT
        try:
            self._mqtt.username_pw_set("codex", "codex-mqtt-2026")
            self._mqtt.connect(self.popos_ip, self.mqtt_port, keepalive=60)
            self._mqtt.loop_start()
            self._mqtt_connected = True
            print(f"[codex_bus] MQTT connected to {self.popos_ip}:{self.mqtt_port}")
        except Exception as e:
            print(f"[codex_bus] MQTT connection failed: {e}")
            self._mqtt_connected = False

        # Redis
        try:
            self._redis = redis_lib.Redis(
                host=self.popos_ip,
                port=self.redis_port,
                password="codex-redis-2026",
                decode_responses=True
            )
            self._redis.ping()
            print(f"[codex_bus] Redis connected to {self.popos_ip}:{self.redis_port}")
        except Exception as e:
            print(f"[codex_bus] Redis connection failed: {e}")
            self._redis = None

    def disconnect(self):
        """Clean disconnect from MQTT and Redis."""
        if self._mqtt_connected:
            self._mqtt.loop_stop()
            self._mqtt.disconnect()
        if self._redis:
            self._redis.close()

    def _timestamp(self) -> str:
        return datetime.now(timezone.utc).isoformat()

    def _publish(self, topic: str, payload: dict):
        """Publish to MQTT and dual-write to Redis."""
        message = json.dumps(payload)

        # MQTT publish
        if self._mqtt_connected:
            result = self._mqtt.publish(topic, message, qos=1)
            if result.rc != mqtt.MQTT_ERR_SUCCESS:
                print(f"[codex_bus] MQTT publish failed: {result.rc}")
        else:
            print(f"[codex_bus] MQTT not connected, skipping publish to {topic}")

        # Redis dual-write (belt and suspenders)
        if self._redis:
            try:
                # Store in a Redis Stream for ordered, replayable events
                self._redis.xadd(
                    f"stream:{topic}",
                    {"data": message},
                    maxlen=10000  # Keep last 10k events per topic
                )
            except Exception as e:
                print(f"[codex_bus] Redis write failed: {e}")

    # --- Convenience methods for each project ---

    def publish_alert(self, alert_data: dict):
        """Sentinel: publish a security alert."""
        payload = {
            "source": self.source,
            "type": "alert",
            "timestamp": self._timestamp(),
            "data": alert_data
        }
        self._publish("codex/sentinel/alerts", payload)

    def publish_iot_alert(self, alert_data: dict):
        """Sentinel: publish an IoT-specific alert."""
        payload = {
            "source": self.source,
            "type": "iot_alert",
            "timestamp": self._timestamp(),
            "data": alert_data
        }
        self._publish("codex/sentinel/iot-alerts", payload)

    def publish_attack_event(self, attack_name: str, status: str, details: dict = None):
        """Netlab: publish attack lifecycle event (started/stopped/completed)."""
        payload = {
            "source": self.source,
            "type": "attack_event",
            "timestamp": self._timestamp(),
            "data": {
                "attack": attack_name,
                "status": status,
                **(details or {})
            }
        }
        self._publish("codex/netlab/attacks", payload)

    def publish_metrics(self, metrics: dict):
        """Syswatch: publish system metrics."""
        payload = {
            "source": self.source,
            "type": "metrics",
            "timestamp": self._timestamp(),
            "data": metrics
        }
        self._publish("codex/syswatch/metrics", payload)

    def publish_heartbeat(self):
        """Any tool: publish a heartbeat ping."""
        payload = {
            "source": self.source,
            "type": "heartbeat",
            "timestamp": self._timestamp()
        }
        self._publish("codex/platform/heartbeat", payload)
