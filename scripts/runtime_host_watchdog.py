#!/usr/bin/env python3
"""Process watchdog for runtime_host_server.py with health-based restart."""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="runtime host watchdog")
    parser.add_argument("--python-exe", default=sys.executable)
    parser.add_argument("--server-script", default="scripts/runtime_host_server.py")
    parser.add_argument("--config-json", required=True)
    parser.add_argument("--health-host", default="127.0.0.1")
    parser.add_argument("--health-tcp-port", type=int, default=0)
    parser.add_argument("--health-udp-port", type=int, default=0)
    parser.add_argument("--require-udp-health", action="store_true")
    parser.add_argument("--health-timeout-ms", type=int, default=1200)
    parser.add_argument("--health-interval-s", type=float, default=3.0)
    parser.add_argument("--start-grace-s", type=float, default=12.0)
    parser.add_argument("--max-consecutive-health-failures", type=int, default=3)
    parser.add_argument("--restart-delay-s", type=float, default=1.5)
    parser.add_argument("--max-restarts", type=int, default=0)
    parser.add_argument("--status-path", default=".tmp/runtime_host_watchdog_status.json")
    parser.add_argument("--event-log-path", default=".tmp/runtime_host_watchdog_events.jsonl")
    parser.add_argument("--stdout-log-path", default=".tmp/runtime_host_watchdog_server.stdout.log")
    parser.add_argument("--stderr-log-path", default=".tmp/runtime_host_watchdog_server.stderr.log")
    return parser.parse_args()


def read_line(sock: socket.socket, max_bytes: int = 4096) -> bytes:
    data = bytearray()
    while len(data) < max_bytes:
        chunk = sock.recv(1)
        if not chunk:
            break
        if chunk == b"\n":
            break
        if chunk != b"\r":
            data.extend(chunk)
    return bytes(data)


def tcp_command(host: str, port: int, timeout_s: float, command: str, max_bytes: int = 4096) -> str:
    with socket.create_connection((host, port), timeout=timeout_s) as sock:
        sock.settimeout(timeout_s)
        sock.sendall((command + "\n").encode("utf-8"))
        response = read_line(sock, max_bytes=max_bytes)
    return response.decode("utf-8", errors="replace")


def udp_command(host: str, port: int, timeout_s: float, command: str) -> str:
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        udp.settimeout(timeout_s)
        udp.sendto((command + "\n").encode("utf-8"), (host, port))
        response, _ = udp.recvfrom(4096)
        return response.decode("utf-8", errors="replace").strip()
    finally:
        udp.close()


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class Watchdog:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.config_path = Path(args.config_json)
        self.server_script = Path(args.server_script)
        self.status_path = Path(args.status_path)
        self.event_log_path = Path(args.event_log_path)
        self.stdout_log_path = Path(args.stdout_log_path)
        self.stderr_log_path = Path(args.stderr_log_path)
        self.timeout_s = max(0.2, float(args.health_timeout_ms) / 1000.0)

        cfg = self._load_config()
        self.health_host = str(args.health_host or cfg.get("host") or "127.0.0.1")
        self.health_tcp_port = int(args.health_tcp_port or cfg.get("tcp_port") or 0)
        self.health_udp_port = int(args.health_udp_port or cfg.get("udp_port") or 0)
        if self.health_tcp_port <= 0:
            raise ValueError("health tcp port is missing (set in config or --health-tcp-port)")
        if self.health_udp_port <= 0:
            self.health_udp_port = self.health_tcp_port + 1

        self.require_udp_health = bool(args.require_udp_health)
        self.max_consecutive_health_failures = max(1, int(args.max_consecutive_health_failures))
        self.start_grace_s = max(1.0, float(args.start_grace_s))
        self.health_interval_s = max(0.5, float(args.health_interval_s))
        self.restart_delay_s = max(0.1, float(args.restart_delay_s))
        self.max_restarts = max(0, int(args.max_restarts))
        self.should_stop = False
        self.child: Optional[subprocess.Popen] = None
        self.restart_count = 0
        self.health_failure_streak = 0
        self.last_start_time = 0.0
        self.last_health_ok = False
        self.last_health_reason = ""

        self._ensure_parent(self.status_path)
        self._ensure_parent(self.event_log_path)
        self._ensure_parent(self.stdout_log_path)
        self._ensure_parent(self.stderr_log_path)

    @staticmethod
    def _ensure_parent(path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)

    def _load_config(self) -> Dict[str, Any]:
        if not self.config_path.exists():
            raise ValueError(f"config json not found: {self.config_path}")
        try:
            cfg = json.loads(self.config_path.read_text(encoding="utf-8-sig"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid config json: {exc}") from exc
        if not isinstance(cfg, dict):
            raise ValueError("config json root must be object")
        return cfg

    def _append_event(self, event: str, details: Dict[str, Any]) -> None:
        payload = {"ts": now_iso(), "event": event, **details}
        with self.event_log_path.open("a", encoding="utf-8") as fp:
            fp.write(json.dumps(payload, ensure_ascii=False) + "\n")

    def _write_status(self) -> None:
        payload = {
            "updated_at": now_iso(),
            "restart_count": self.restart_count,
            "health_failure_streak": self.health_failure_streak,
            "last_health_ok": self.last_health_ok,
            "last_health_reason": self.last_health_reason,
            "child_pid": self.child.pid if self.child else 0,
            "child_running": bool(self.child and self.child.poll() is None),
            "health_host": self.health_host,
            "health_tcp_port": self.health_tcp_port,
            "health_udp_port": self.health_udp_port,
            "config_json": str(self.config_path),
            "server_script": str(self.server_script),
        }
        self.status_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    def _start_child(self) -> None:
        if not self.server_script.exists():
            raise RuntimeError(f"server script not found: {self.server_script}")
        command = [
            str(self.args.python_exe),
            str(self.server_script),
            "--config-json",
            str(self.config_path),
        ]
        with self.stdout_log_path.open("a", encoding="utf-8") as out_fp, self.stderr_log_path.open(
            "a", encoding="utf-8"
        ) as err_fp:
            self.child = subprocess.Popen(command, stdout=out_fp, stderr=err_fp)
        self.last_start_time = time.time()
        self.health_failure_streak = 0
        self.last_health_ok = False
        self.last_health_reason = "starting"
        self._append_event("child_started", {"pid": self.child.pid, "command": command})
        self._write_status()

    def _stop_child(self, reason: str) -> None:
        if self.child is None:
            return
        child = self.child
        self.child = None
        if child.poll() is not None:
            self._append_event("child_already_stopped", {"pid": child.pid, "code": child.returncode, "reason": reason})
            self._write_status()
            return
        try:
            tcp_command(self.health_host, self.health_tcp_port, self.timeout_s, "__STOP__")
        except Exception:
            pass
        try:
            child.wait(timeout=4.0)
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=4.0)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=4.0)
        self._append_event("child_stopped", {"pid": child.pid, "code": child.returncode, "reason": reason})
        self._write_status()

    def _restart_child(self, reason: str) -> bool:
        self.restart_count += 1
        if self.max_restarts > 0 and self.restart_count > self.max_restarts:
            self._append_event(
                "restart_limit_reached",
                {"restart_count": self.restart_count, "max_restarts": self.max_restarts, "reason": reason},
            )
            return False
        self._append_event("restart_scheduled", {"restart_count": self.restart_count, "reason": reason})
        self._stop_child(f"restart:{reason}")
        time.sleep(self.restart_delay_s)
        self._start_child()
        return True

    def _health_check(self) -> tuple[bool, str]:
        if self.child is None or self.child.poll() is not None:
            return False, "child_not_running"
        try:
            tcp_reply = tcp_command(self.health_host, self.health_tcp_port, self.timeout_s, "M1_CONN_PING")
            if tcp_reply != "M1_CONN_PONG":
                return False, f"bad_tcp_reply:{tcp_reply!r}"
        except Exception as exc:  # pylint: disable=broad-except
            return False, f"tcp_error:{exc.__class__.__name__}:{exc}"

        if self.require_udp_health:
            try:
                udp_reply = udp_command(self.health_host, self.health_udp_port, self.timeout_s, "M1_UDP_PING")
                if udp_reply != "M1_UDP_PONG":
                    return False, f"bad_udp_reply:{udp_reply!r}"
            except Exception as exc:  # pylint: disable=broad-except
                return False, f"udp_error:{exc.__class__.__name__}:{exc}"

        return True, "ok"

    def run(self) -> int:
        self._append_event("watchdog_started", {"pid": os.getpid()})
        self._start_child()
        while not self.should_stop:
            if self.child is None:
                self._append_event("child_missing", {})
                if not self._restart_child("child_missing"):
                    return 2

            child = self.child
            assert child is not None

            if child.poll() is not None:
                self.last_health_ok = False
                self.last_health_reason = f"child_exit:{child.returncode}"
                self._append_event("child_exited", {"code": child.returncode, "pid": child.pid})
                if not self._restart_child(f"child_exited:{child.returncode}"):
                    return 2
                time.sleep(self.restart_delay_s)
                continue

            ok, reason = self._health_check()
            self.last_health_ok = ok
            self.last_health_reason = reason
            if ok:
                self.health_failure_streak = 0
                self._write_status()
            else:
                self.health_failure_streak += 1
                self._append_event(
                    "health_check_failed",
                    {"reason": reason, "streak": self.health_failure_streak, "pid": child.pid},
                )
                self._write_status()
                if time.time() - self.last_start_time >= self.start_grace_s and (
                    self.health_failure_streak >= self.max_consecutive_health_failures
                ):
                    if not self._restart_child(f"health_failed:{reason}"):
                        return 2
            time.sleep(self.health_interval_s)

        self._append_event("watchdog_stopping", {})
        self._stop_child("watchdog_stop")
        return 0

    def stop(self, signum: int) -> None:
        self.should_stop = True
        self._append_event("signal_received", {"signal": int(signum)})


def main() -> int:
    args = parse_args()
    try:
        watchdog = Watchdog(args)
    except ValueError as exc:
        print(f"watchdog_config_error: {exc}", file=sys.stderr, flush=True)
        return 2

    def _on_signal(signum, _frame) -> None:
        watchdog.stop(signum)

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)
    try:
        return watchdog.run()
    except Exception as exc:  # pylint: disable=broad-except
        print(f"watchdog_runtime_error: {exc}", file=sys.stderr, flush=True)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
