#!/usr/bin/env python3
"""Concurrent TCP/UDP stress runner for runtime_host_server.py."""

from __future__ import annotations

import argparse
import json
import socket
import threading
import time
from pathlib import Path
from typing import Any, Dict, List


class ProtocolStats:
    def __init__(self, name: str) -> None:
        self.name = name
        self.attempts = 0
        self.successes = 0
        self.failures = 0
        self.bytes_sent = 0
        self.bytes_received = 0
        self.latencies_ms: List[float] = []
        self.error_reasons: Dict[str, int] = {}
        self._lock = threading.Lock()

    def record_success(self, latency_ms: float, sent: int, received: int) -> None:
        with self._lock:
            self.attempts += 1
            self.successes += 1
            self.bytes_sent += max(0, sent)
            self.bytes_received += max(0, received)
            self.latencies_ms.append(max(0.0, latency_ms))

    def record_failure(self, reason: str, sent: int = 0, received: int = 0) -> None:
        reason_key = reason.strip() or "unknown"
        with self._lock:
            self.attempts += 1
            self.failures += 1
            self.bytes_sent += max(0, sent)
            self.bytes_received += max(0, received)
            self.error_reasons[reason_key] = self.error_reasons.get(reason_key, 0) + 1

    @staticmethod
    def _percentile(values: List[float], q: float) -> float:
        if not values:
            return 0.0
        sorted_values = sorted(values)
        if len(sorted_values) == 1:
            return float(sorted_values[0])
        index = q * (len(sorted_values) - 1)
        lo = int(index)
        hi = min(lo + 1, len(sorted_values) - 1)
        frac = index - lo
        return float(sorted_values[lo] * (1.0 - frac) + sorted_values[hi] * frac)

    def snapshot(self, duration_s: float) -> Dict[str, Any]:
        with self._lock:
            attempts = int(self.attempts)
            successes = int(self.successes)
            failures = int(self.failures)
            latencies = list(self.latencies_ms)
            reasons = dict(self.error_reasons)
            sent = int(self.bytes_sent)
            received = int(self.bytes_received)

        success_rate = float(successes / attempts) if attempts > 0 else 0.0
        failure_rate = float(failures / attempts) if attempts > 0 else 0.0
        throughput_rps = float(successes / duration_s) if duration_s > 0 else 0.0
        return {
            "protocol": self.name,
            "attempts": attempts,
            "successes": successes,
            "failures": failures,
            "success_rate": success_rate,
            "failure_rate": failure_rate,
            "throughput_rps": throughput_rps,
            "bytes_sent": sent,
            "bytes_received": received,
            "latency_ms_p50": self._percentile(latencies, 0.50),
            "latency_ms_p95": self._percentile(latencies, 0.95),
            "latency_ms_max": max(latencies) if latencies else 0.0,
            "error_reasons": reasons,
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="runtime host stress runner")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, required=True)
    parser.add_argument("--udp-port", type=int, required=True)
    parser.add_argument("--duration-s", type=float, default=20.0)
    parser.add_argument("--tcp-workers", type=int, default=12)
    parser.add_argument("--udp-workers", type=int, default=6)
    parser.add_argument("--timeout-ms", type=int, default=1200)
    parser.add_argument("--output-path", required=True)
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


def tcp_worker(
    host: str,
    port: int,
    timeout_s: float,
    deadline: float,
    stats: ProtocolStats,
) -> None:
    request = b"M1_CONN_PING\n"
    while time.perf_counter() < deadline:
        started = time.perf_counter()
        try:
            with socket.create_connection((host, port), timeout=timeout_s) as sock:
                sock.settimeout(timeout_s)
                sock.sendall(request)
                response = read_line(sock)
            latency_ms = (time.perf_counter() - started) * 1000.0
            if response == b"M1_CONN_PONG":
                stats.record_success(latency_ms, len(request), len(response))
            else:
                stats.record_failure(f"bad_tcp_reply:{response.decode('utf-8', errors='replace')}", len(request), len(response))
        except socket.timeout:
            stats.record_failure("tcp_timeout", len(request), 0)
        except OSError as exc:
            stats.record_failure(f"tcp_oserror:{exc.__class__.__name__}", len(request), 0)


def udp_worker(
    host: str,
    port: int,
    timeout_s: float,
    deadline: float,
    stats: ProtocolStats,
) -> None:
    request = b"M1_UDP_PING\n"
    while time.perf_counter() < deadline:
        started = time.perf_counter()
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            udp.settimeout(timeout_s)
            udp.sendto(request, (host, port))
            response, _ = udp.recvfrom(4096)
            latency_ms = (time.perf_counter() - started) * 1000.0
            reply = response.strip()
            if reply == b"M1_UDP_PONG":
                stats.record_success(latency_ms, len(request), len(response))
            else:
                stats.record_failure(f"bad_udp_reply:{reply.decode('utf-8', errors='replace')}", len(request), len(response))
        except socket.timeout:
            stats.record_failure("udp_timeout", len(request), 0)
        except OSError as exc:
            stats.record_failure(f"udp_oserror:{exc.__class__.__name__}", len(request), 0)
        finally:
            udp.close()


def fetch_metrics(host: str, port: int, timeout_s: float) -> Dict[str, Any]:
    request = b"__METRICS__\n"
    try:
        with socket.create_connection((host, port), timeout=timeout_s) as sock:
            sock.settimeout(timeout_s)
            sock.sendall(request)
            payload = read_line(sock, max_bytes=32768)
        text = payload.decode("utf-8", errors="replace")
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            return parsed
        return {"metrics_parse_error": "metrics payload is not an object"}
    except Exception as exc:  # pylint: disable=broad-except
        return {"metrics_fetch_error": f"{exc.__class__.__name__}: {exc}"}


def main() -> int:
    args = parse_args()
    duration_s = max(1.0, float(args.duration_s))
    timeout_s = max(0.2, float(args.timeout_ms) / 1000.0)
    tcp_workers = max(0, int(args.tcp_workers))
    udp_workers = max(0, int(args.udp_workers))
    host = str(args.host)
    tcp_port = int(args.tcp_port)
    udp_port = int(args.udp_port)

    tcp_stats = ProtocolStats("tcp")
    udp_stats = ProtocolStats("udp")
    start_ts = time.time()
    started = time.perf_counter()
    deadline = started + duration_s

    threads: List[threading.Thread] = []
    for idx in range(tcp_workers):
        thread = threading.Thread(
            target=tcp_worker,
            args=(host, tcp_port, timeout_s, deadline, tcp_stats),
            name=f"tcp-worker-{idx}",
            daemon=True,
        )
        threads.append(thread)
    for idx in range(udp_workers):
        thread = threading.Thread(
            target=udp_worker,
            args=(host, udp_port, timeout_s, deadline, udp_stats),
            name=f"udp-worker-{idx}",
            daemon=True,
        )
        threads.append(thread)

    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    elapsed_s = max(0.001, time.perf_counter() - started)
    tcp_snapshot = tcp_stats.snapshot(elapsed_s)
    udp_snapshot = udp_stats.snapshot(elapsed_s)
    total_attempts = int(tcp_snapshot["attempts"]) + int(udp_snapshot["attempts"])
    total_successes = int(tcp_snapshot["successes"]) + int(udp_snapshot["successes"])
    total_failures = int(tcp_snapshot["failures"]) + int(udp_snapshot["failures"])
    overall_failure_rate = float(total_failures / total_attempts) if total_attempts > 0 else 1.0
    throughput_rps = float(total_successes / elapsed_s)
    metrics = fetch_metrics(host, tcp_port, timeout_s)

    run_ok = (
        total_attempts > 0
        and total_successes > 0
        and int(tcp_snapshot["attempts"]) > 0
        and int(udp_snapshot["attempts"]) > 0
    )

    report = {
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start_ts)),
        "run_ok": run_ok,
        "config": {
            "host": host,
            "tcp_port": tcp_port,
            "udp_port": udp_port,
            "duration_s": duration_s,
            "tcp_workers": tcp_workers,
            "udp_workers": udp_workers,
            "timeout_ms": int(args.timeout_ms),
        },
        "overall": {
            "elapsed_s": elapsed_s,
            "attempts": total_attempts,
            "successes": total_successes,
            "failures": total_failures,
            "failure_rate": overall_failure_rate,
            "throughput_rps": throughput_rps,
        },
        "tcp": tcp_snapshot,
        "udp": udp_snapshot,
        "metrics": metrics,
    }

    output_path = Path(args.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"stress_report={output_path}")
    return 0 if run_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
