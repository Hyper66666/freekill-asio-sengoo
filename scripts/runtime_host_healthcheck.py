#!/usr/bin/env python3
"""Health probe for runtime_host_server endpoints."""

from __future__ import annotations

import argparse
import json
import socket
import time
from typing import Tuple


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="runtime host healthcheck")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, required=True)
    parser.add_argument("--udp-port", type=int, default=0)
    parser.add_argument("--timeout-ms", type=int, default=1200)
    parser.add_argument("--require-udp", action="store_true")
    parser.add_argument("--max-error-count", type=int, default=-1)
    parser.add_argument("--min-timer-tick-count", type=int, default=-1)
    parser.add_argument("--min-io-poll-count", type=int, default=-1)
    parser.add_argument("--json-output", action="store_true")
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
        payload = (command + "\n").encode("utf-8")
        sock.sendall(payload)
        response = read_line(sock, max_bytes=max_bytes)
    return response.decode("utf-8", errors="replace")


def udp_command(host: str, port: int, timeout_s: float, command: str) -> str:
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        udp.settimeout(timeout_s)
        payload = (command + "\n").encode("utf-8")
        udp.sendto(payload, (host, port))
        response, _ = udp.recvfrom(4096)
        return response.decode("utf-8", errors="replace").strip()
    finally:
        udp.close()


def bool_check(name: str, condition: bool, reason_if_fail: str) -> Tuple[bool, str]:
    if condition:
        return True, ""
    return False, f"{name}: {reason_if_fail}"


def main() -> int:
    args = parse_args()
    host = str(args.host)
    tcp_port = int(args.tcp_port)
    udp_port = int(args.udp_port) if int(args.udp_port) > 0 else tcp_port + 1
    timeout_s = max(0.2, float(args.timeout_ms) / 1000.0)
    report = {
        "generated_at_unix_s": int(time.time()),
        "host": host,
        "tcp_port": tcp_port,
        "udp_port": udp_port,
        "ok": False,
        "tcp_reply": "",
        "udp_reply": "",
        "metrics": {},
        "reasons": [],
    }

    reasons = []
    try:
        tcp_reply = tcp_command(host, tcp_port, timeout_s, "M1_CONN_PING")
        report["tcp_reply"] = tcp_reply
        ok, reason = bool_check("tcp_ping", tcp_reply == "M1_CONN_PONG", f"unexpected reply={tcp_reply!r}")
        if not ok:
            reasons.append(reason)
    except Exception as exc:  # pylint: disable=broad-except
        reasons.append(f"tcp_ping_error: {exc.__class__.__name__}: {exc}")

    if args.require_udp:
        try:
            udp_reply = udp_command(host, udp_port, timeout_s, "M1_UDP_PING")
            report["udp_reply"] = udp_reply
            ok, reason = bool_check("udp_ping", udp_reply == "M1_UDP_PONG", f"unexpected reply={udp_reply!r}")
            if not ok:
                reasons.append(reason)
        except Exception as exc:  # pylint: disable=broad-except
            reasons.append(f"udp_ping_error: {exc.__class__.__name__}: {exc}")

    try:
        metrics_raw = tcp_command(host, tcp_port, timeout_s, "__METRICS__", max_bytes=32768)
        metrics = json.loads(metrics_raw)
        if isinstance(metrics, dict):
            report["metrics"] = metrics
            if int(args.max_error_count) >= 0:
                ok, reason = bool_check(
                    "metrics_error_count",
                    int(metrics.get("error_count", 0)) <= int(args.max_error_count),
                    f"error_count={metrics.get('error_count', 0)} > {int(args.max_error_count)}",
                )
                if not ok:
                    reasons.append(reason)
            if int(args.min_timer_tick_count) >= 0:
                ok, reason = bool_check(
                    "metrics_timer_tick_count",
                    int(metrics.get("timer_tick_count", 0)) >= int(args.min_timer_tick_count),
                    f"timer_tick_count={metrics.get('timer_tick_count', 0)} < {int(args.min_timer_tick_count)}",
                )
                if not ok:
                    reasons.append(reason)
            if int(args.min_io_poll_count) >= 0:
                ok, reason = bool_check(
                    "metrics_io_poll_count",
                    int(metrics.get("io_poll_count", 0)) >= int(args.min_io_poll_count),
                    f"io_poll_count={metrics.get('io_poll_count', 0)} < {int(args.min_io_poll_count)}",
                )
                if not ok:
                    reasons.append(reason)
        else:
            reasons.append("metrics_not_object")
    except Exception as exc:  # pylint: disable=broad-except
        reasons.append(f"metrics_error: {exc.__class__.__name__}: {exc}")

    report["reasons"] = reasons
    report["ok"] = len(reasons) == 0

    if args.json_output:
        print(json.dumps(report, separators=(",", ":"), ensure_ascii=False))
    else:
        if report["ok"]:
            print("HEALTH_OK")
        else:
            print("HEALTH_FAIL")
            for reason in reasons:
                print(reason)

    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
