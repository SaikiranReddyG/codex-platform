#!/usr/bin/env python3
"""
syswatch_wrapper.py — Reads /proc metrics and publishes to MQTT every 5 seconds.
Runs alongside syswatch on Arch VM.

Usage:
    python3 ~/codex-workspace/codex-platform/syswatch_wrapper.py
"""

import time
import json
import sys
import os

# Resolve codex-platform root dynamically so this works across usernames/paths.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)
from codex_bus import CodexBus


def read_cpu():
    """Read CPU usage from /proc/stat."""
    with open('/proc/stat') as f:
        parts = f.readline().split()
    # user, nice, system, idle, iowait, irq, softirq
    vals = [int(x) for x in parts[1:8]]
    return vals


def cpu_percent(prev, curr):
    """Calculate CPU percent between two /proc/stat reads."""
    prev_idle = prev[3] + prev[4]
    curr_idle = curr[3] + curr[4]
    prev_total = sum(prev)
    curr_total = sum(curr)
    diff_total = curr_total - prev_total
    diff_idle = curr_idle - prev_idle
    if diff_total == 0:
        return 0.0
    return round((1.0 - diff_idle / diff_total) * 100, 1)


def read_memory():
    """Read memory from /proc/meminfo."""
    info = {}
    with open('/proc/meminfo') as f:
        for line in f:
            parts = line.split()
            key = parts[0].rstrip(':')
            info[key] = int(parts[1])  # in kB
    total = info.get('MemTotal', 0)
    available = info.get('MemAvailable', 0)
    used = total - available
    swap_total = info.get('SwapTotal', 0)
    swap_free = info.get('SwapFree', 0)
    swap_used = swap_total - swap_free
    return {
        'total_mb': round(total / 1024, 1),
        'used_mb': round(used / 1024, 1),
        'available_mb': round(available / 1024, 1),
        'percent': round((used / total) * 100, 1) if total > 0 else 0,
        'swap_used_mb': round(swap_used / 1024, 1),
    }


def read_disk():
    """Read disk usage from statvfs."""
    st = os.statvfs('/')
    total = st.f_blocks * st.f_frsize
    free = st.f_bfree * st.f_frsize
    used = total - free
    return {
        'total_gb': round(total / (1024**3), 1),
        'used_gb': round(used / (1024**3), 1),
        'percent': round((used / total) * 100, 1) if total > 0 else 0,
    }


def read_net():
    """Read network bytes from /proc/net/dev."""
    with open('/proc/net/dev') as f:
        lines = f.readlines()
    rx_total = 0
    tx_total = 0
    for line in lines[2:]:  # skip headers
        parts = line.split()
        iface = parts[0].rstrip(':')
        if iface == 'lo':
            continue
        rx_total += int(parts[1])
        tx_total += int(parts[9])
    return rx_total, tx_total


def main():
    bus = CodexBus(source='syswatch')
    bus.connect()

    prev_cpu = read_cpu()
    prev_rx, prev_tx = read_net()
    time.sleep(1)

    print('[syswatch_wrapper] Publishing metrics every 5 seconds. Ctrl+C to stop.')

    try:
        while True:
            curr_cpu = read_cpu()
            cpu = cpu_percent(prev_cpu, curr_cpu)
            prev_cpu = curr_cpu

            mem = read_memory()
            disk = read_disk()

            curr_rx, curr_tx = read_net()
            net_rx_rate = round((curr_rx - prev_rx) / 5, 0)  # bytes/sec
            net_tx_rate = round((curr_tx - prev_tx) / 5, 0)
            prev_rx, prev_tx = curr_rx, curr_tx

            metrics = {
                'cpu_percent': cpu,
                'mem_percent': mem['percent'],
                'mem_used_mb': mem['used_mb'],
                'mem_available_mb': mem['available_mb'],
                'swap_used_mb': mem['swap_used_mb'],
                'disk_percent': disk['percent'],
                'disk_used_gb': disk['used_gb'],
                'net_rx_bytes_sec': net_rx_rate,
                'net_tx_bytes_sec': net_tx_rate,
            }

            bus.publish_metrics(metrics)
            time.sleep(5)

    except KeyboardInterrupt:
        print('\n[syswatch_wrapper] Stopped.')
    finally:
        bus.disconnect()


if __name__ == '__main__':
    main()
