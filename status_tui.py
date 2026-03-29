#!/usr/bin/env python3
"""
status_tui.py — Minimal live status view for codex-platform.

Runs on Pop!_OS. Shows green/yellow/red status for:
- Docker services (mosquitto, redis, n8n, grafana)
- Pipelines (MQTT metrics flowing, Redis streams, SQLite recent inserts)
- Arch VM connectivity + key sensor processes (sentinel, syswatch_wrapper)

No external dependencies: uses Python stdlib + curses.
"""

from __future__ import annotations

import curses
import json
import os
import shlex
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone


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


_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_load_dotenv(os.path.join(_SCRIPT_DIR, ".env"))


def _required_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None or value == "":
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


ARCH_IP = _required_env("CODEX_ARCH_IP")
ARCH_USER = _required_env("CODEX_ARCH_USER")
POPOS_IP = _required_env("CODEX_POPOS_IP")
LOCAL_HOST = _required_env("CODEX_LOCAL_HOST")

MQTT_PORT = int(_required_env("CODEX_MQTT_PORT"))
MQTT_USER = _required_env("CODEX_MQTT_USER")
MQTT_PASS = _required_env("CODEX_MQTT_PASS")

REDIS_PASS = _required_env("CODEX_REDIS_PASS")

_DEFAULT_COMPOSE_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_DIR = os.path.abspath(os.environ.get("CODEX_COMPOSE_DIR", _DEFAULT_COMPOSE_DIR))
SQLITE_DB = os.path.join(COMPOSE_DIR, "sqlite", "codex.db")
LOG_DIR = os.path.join(COMPOSE_DIR, "logs")

ARCH_LOG_DIR = _required_env("CODEX_ARCH_LOG_DIR")
ARCH_SYSWATCH_LOG = f"{ARCH_LOG_DIR}/syswatch.log"
ARCH_SENTINEL_STDOUT_LOG = f"{ARCH_LOG_DIR}/sentinel_stdout.log"


class Level:
    OK = "ok"
    WARN = "warn"
    FAIL = "fail"


@dataclass(frozen=True)
class CheckResult:
    name: str
    level: str
    detail: str = ""
    hint: str = ""


def _run(cmd: str, timeout_s: float = 3.0) -> tuple[int, str]:
    try:
        p = subprocess.run(
            cmd,
            shell=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout_s,
            text=True,
        )
        return p.returncode, (p.stdout or "").strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def _docker_container_running(name: str) -> CheckResult:
    # docker inspect uses Go templates; braces must be doubled and quoted.
    rc, out = _run(f"docker inspect --format='{{{{.State.Status}}}}' {shlex.quote(name)}", 2.0)
    if rc != 0 or not out:
        return CheckResult(f"docker:{name}", Level.FAIL, "not found")
    if out != "running":
        return CheckResult(f"docker:{name}", Level.FAIL, out)
    # Health is optional; treat missing healthcheck as WARN not FAIL.
    rc2, health = _run(
        f"docker inspect --format='{{{{if .State.Health}}}}{{{{.State.Health.Status}}}}{{{{else}}}}no-healthcheck{{{{end}}}}' {shlex.quote(name)}",
        2.0,
    )
    health = health or "unknown"
    if health in ("healthy", "no-healthcheck"):
        lvl = Level.OK if health == "healthy" else Level.WARN
        return CheckResult(f"docker:{name}", lvl, health)
    return CheckResult(f"docker:{name}", Level.WARN, health)


def _mqtt_metrics_flow() -> CheckResult:
    # Grab one message and just parse JSON to ensure flow.
    cmd = (
        f"timeout 3 mosquitto_sub -h {shlex.quote(LOCAL_HOST)} -p {MQTT_PORT} "
        f"-u {shlex.quote(MQTT_USER)} -P {shlex.quote(MQTT_PASS)} "
        f"-t codex/syswatch/metrics -C 1"
    )
    rc, out = _run(cmd, 4.0)
    if rc != 0 or not out:
        return CheckResult(
            "mqtt:syswatch_metrics",
            Level.FAIL,
            "no message",
            hint="Check Arch syswatch_wrapper + Mosquitto auth",
        )
    try:
        msg = json.loads(out)
        ts = msg.get("timestamp", "")
        return CheckResult("mqtt:syswatch_metrics", Level.OK, ts or "message received")
    except Exception:
        return CheckResult("mqtt:syswatch_metrics", Level.WARN, "message received (non-JSON)")


def _redis_stream_len(stream: str) -> CheckResult:
    cmd = (
        f"docker exec -e REDISCLI_AUTH={shlex.quote(REDIS_PASS)} "
        f"codex-redis redis-cli XLEN {shlex.quote(stream)}"
    )
    rc, out = _run(cmd, 3.0)
    if rc != 0 or not out:
        return CheckResult(f"redis:{stream}", Level.FAIL, "unreachable/auth?")
    out = out.strip().replace("\r", "")
    if out.isdigit():
        n = int(out)
        lvl = Level.OK if n > 0 else Level.WARN
        return CheckResult(f"redis:{stream}", lvl, f"{n} entries")
    return CheckResult(f"redis:{stream}", Level.WARN, out[:60])


def _sqlite_recent_metrics() -> CheckResult:
    if not os.path.exists(SQLITE_DB):
        return CheckResult("sqlite:metrics_recent", Level.FAIL, "db missing", hint=SQLITE_DB)
    cmd = (
        f"sqlite3 {shlex.quote(SQLITE_DB)} "
        "\"select count(*) from metrics where timestamp > datetime('now','-5 minutes');\""
    )
    rc, out = _run(cmd, 2.5)
    if rc != 0 or not out or not out.strip().isdigit():
        return CheckResult("sqlite:metrics_recent", Level.FAIL, "query failed")
    n = int(out.strip())
    lvl = Level.OK if n > 0 else Level.FAIL
    return CheckResult("sqlite:metrics_recent", lvl, f"{n} rows/5m")


def _arch_ping() -> CheckResult:
    rc, _ = _run(f"ping -c 1 -W 2 {shlex.quote(ARCH_IP)}", 3.0)
    if rc == 0:
        return CheckResult("arch:ping", Level.OK, "ok")
    return CheckResult("arch:ping", Level.FAIL, "unreachable")


def _arch_ssh(cmd: str, timeout_s: float = 4.0) -> tuple[int, str]:
    return _run(
        f"ssh -o BatchMode=yes -o ConnectTimeout=3 {shlex.quote(ARCH_USER)}@{shlex.quote(ARCH_IP)} {shlex.quote(cmd)}",
        timeout_s,
    )


def _arch_proc(name: str, pattern: str) -> CheckResult:
    rc, out = _arch_ssh(f"pgrep -fa {shlex.quote(pattern)} | head -n 1", 4.0)
    if rc == 0 and out:
        return CheckResult(f"arch:{name}", Level.OK, out.strip()[:80])
    return CheckResult(f"arch:{name}", Level.WARN, "not running")


def _arch_netns_count() -> CheckResult:
    rc, out = _arch_ssh("sudo -n ip netns list 2>/dev/null | wc -l", 4.0)
    out = (out or "").strip()
    if rc != 0 or not out.isdigit():
        return CheckResult("arch:netns", Level.WARN, "unknown")
    n = int(out)
    lvl = Level.OK if n >= 4 else Level.WARN
    return CheckResult("arch:netns", lvl, f"{n} namespaces")


def _arch_bridge_exists() -> CheckResult:
    rc, _ = _arch_ssh("ip link show br-lab >/dev/null 2>&1", 4.0)
    return CheckResult("arch:br-lab", Level.OK if rc == 0 else Level.WARN, "present" if rc == 0 else "missing")


def _last_log_line(path: str) -> str:
    rc, out = _run(f"tail -n 1 {shlex.quote(path)}", 1.5)
    if rc == 0 and out:
        return out.strip()[:120]
    return ""


def _fmt_time() -> str:
    return datetime.now(timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M:%S")


def gather_checks() -> list[CheckResult]:
    results: list[CheckResult] = []

    # Pop!_OS Docker services
    for c in ("codex-mosquitto", "codex-redis", "codex-n8n", "codex-grafana"):
        results.append(_docker_container_running(c))

    # Pipelines
    results.append(_mqtt_metrics_flow())
    results.append(_sqlite_recent_metrics())
    results.append(_redis_stream_len("stream:codex/syswatch/metrics"))
    results.append(_redis_stream_len("stream:codex/sentinel/alerts"))
    results.append(_redis_stream_len("stream:codex/netlab/attacks"))

    # Arch status
    results.append(_arch_ping())
    # SSH quick check
    rc, _ = _arch_ssh("echo ok", 4.0)
    results.append(CheckResult("arch:ssh", Level.OK if rc == 0 else Level.FAIL, "ok" if rc == 0 else "failed"))
    if rc == 0:
        results.append(_arch_netns_count())
        results.append(_arch_bridge_exists())
        results.append(_arch_proc("sentinel", "python3 .*src/main.py"))
        results.append(_arch_proc("syswatch_wrapper", "syswatch_wrapper"))

    return results


def _level_color(level: str) -> int:
    if level == Level.OK:
        return 1
    if level == Level.WARN:
        return 2
    return 3


def _overall_level(results: list[CheckResult]) -> str:
    if any(r.level == Level.FAIL for r in results):
        return Level.FAIL
    if any(r.level == Level.WARN for r in results):
        return Level.WARN
    return Level.OK


def tui(stdscr) -> None:
    curses.curs_set(0)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_GREEN, -1)
    curses.init_pair(2, curses.COLOR_YELLOW, -1)
    curses.init_pair(3, curses.COLOR_RED, -1)
    curses.init_pair(4, curses.COLOR_CYAN, -1)

    refresh_s = 2.0
    stdscr.nodelay(True)

    while True:
        ch = stdscr.getch()
        if ch in (ord("q"), ord("Q")):
            return
        if ch in (ord("+"), ord("=")):
            refresh_s = max(0.5, refresh_s - 0.5)
        if ch in (ord("-"), ord("_")):
            refresh_s = min(10.0, refresh_s + 0.5)

        results = gather_checks()
        overall = _overall_level(results)

        stdscr.erase()
        h, w = stdscr.getmaxyx()

        title = f"codex-platform status  [{_fmt_time()}]  refresh={refresh_s:.1f}s  (q to quit)"
        stdscr.addnstr(0, 0, title, w - 1, curses.color_pair(4))

        overall_str = {"ok": "ALL_GREEN", "warn": "WARNINGS", "fail": "FAILURES"}[overall]
        stdscr.addnstr(1, 0, f"overall: {overall_str}", w - 1, curses.color_pair(_level_color(overall)))

        stdscr.addnstr(3, 0, "Pop!_OS services", w - 1, curses.A_BOLD)
        y = 4
        for r in results:
            if not r.name.startswith("docker:"):
                continue
            stdscr.addnstr(y, 2, f"{r.name[7:]:<14} {r.detail}", w - 3, curses.color_pair(_level_color(r.level)))
            y += 1

        y += 1
        stdscr.addnstr(y, 0, "Pipelines", w - 1, curses.A_BOLD)
        y += 1
        for key in ("mqtt:syswatch_metrics", "sqlite:metrics_recent", "redis:stream:codex/syswatch/metrics", "redis:stream:codex/sentinel/alerts", "redis:stream:codex/netlab/attacks"):
            r = next((x for x in results if x.name == key), None)
            if not r:
                continue
            stdscr.addnstr(y, 2, f"{r.name:<32} {r.detail}", w - 3, curses.color_pair(_level_color(r.level)))
            y += 1

        y += 1
        stdscr.addnstr(y, 0, "Arch VM", w - 1, curses.A_BOLD)
        y += 1
        for key in ("arch:ping", "arch:ssh", "arch:netns", "arch:br-lab", "arch:sentinel", "arch:syswatch_wrapper"):
            r = next((x for x in results if x.name == key), None)
            if not r:
                continue
            stdscr.addnstr(y, 2, f"{r.name:<20} {r.detail}", w - 3, curses.color_pair(_level_color(r.level)))
            y += 1

        # Bottom: log pointers + last log line for quick hints
        y = max(y + 1, h - 5)
        stdscr.hline(y, 0, "-", w - 1)
        y += 1
        stdscr.addnstr(y, 0, f"logs Pop!_OS: {LOG_DIR}", w - 1)
        y += 1
        stdscr.addnstr(y, 0, f"logs Arch:   {ARCH_LOG_DIR}", w - 1)
        y += 1

        last = _last_log_line(os.path.join(LOG_DIR, "metrics_receiver.log"))
        if last:
            stdscr.addnstr(y, 0, f"last metrics_receiver.log: {last}", w - 1)

        stdscr.refresh()
        time.sleep(refresh_s)


def main() -> None:
    if not os.path.isdir(LOG_DIR):
        os.makedirs(LOG_DIR, exist_ok=True)
    curses.wrapper(tui)


if __name__ == "__main__":
    main()

