#!/usr/bin/env python3
"""Deployable runtime host with TCP/UDP I/O, event loop, Lua bridge, and SQLite."""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import signal
import sqlite3
import subprocess
import threading
import time
import zlib
from pathlib import Path
from typing import Dict, Optional, Set, Tuple

try:
    from google.protobuf import descriptor_pb2
    from google.protobuf import descriptor_pool
    from google.protobuf import message_factory

    PROTOBUF_AVAILABLE = True
except Exception:  # pragma: no cover - optional dependency on deployment host
    PROTOBUF_AVAILABLE = False


def build_protobuf_models():
    if not PROTOBUF_AVAILABLE:
        return None, None

    file_desc = descriptor_pb2.FileDescriptorProto()
    file_desc.name = "runtime_wire.proto"
    file_desc.package = "runtime"

    ping = file_desc.message_type.add()
    ping.name = "Ping"
    field = ping.field.add()
    field.name = "payload"
    field.number = 1
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
    field = ping.field.add()
    field.name = "seq"
    field.number = 2
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_UINT32
    field = ping.field.add()
    field.name = "keep"
    field.number = 3
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_BOOL

    pong = file_desc.message_type.add()
    pong.name = "Pong"
    field = pong.field.add()
    field.name = "payload"
    field.number = 1
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_STRING
    field = pong.field.add()
    field.name = "seq"
    field.number = 2
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_UINT32
    field = pong.field.add()
    field.name = "ok"
    field.number = 3
    field.label = descriptor_pb2.FieldDescriptorProto.LABEL_OPTIONAL
    field.type = descriptor_pb2.FieldDescriptorProto.TYPE_BOOL

    pool = descriptor_pool.DescriptorPool()
    pool.Add(file_desc)
    ping_desc = pool.FindMessageTypeByName("runtime.Ping")
    pong_desc = pool.FindMessageTypeByName("runtime.Pong")
    ping_cls = message_factory.GetMessageClass(ping_desc)
    pong_cls = message_factory.GetMessageClass(pong_desc)
    return ping_cls, pong_cls


class RuntimeHostUdpProtocol(asyncio.DatagramProtocol):
    def __init__(self, host: "RuntimeHost") -> None:
        self.host = host
        self.transport: Optional[asyncio.DatagramTransport] = None

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = transport  # type: ignore[assignment]

    def datagram_received(self, data: bytes, addr) -> None:
        if self.transport is None:
            return
        self.host.on_udp_datagram(data, addr, self.transport)

    def error_received(self, exc: Exception) -> None:
        self.host.increment_metric("error_count")


class RuntimeHost:
    def __init__(
        self,
        host: str,
        tcp_port: int,
        udp_port: int,
        runtime_name: str,
        db_path: Path,
        thread_count: int,
        tick_interval_ms: int,
        task_budget: int,
        lua_script_path: Path | None,
        lua_command: str,
        drift_mode: str,
    ) -> None:
        self.host = host
        self.tcp_port = tcp_port
        self.udp_port = udp_port
        self.runtime_name = runtime_name
        self.db_path = db_path
        self.thread_count = max(1, thread_count)
        self.tick_interval_ms = max(1, tick_interval_ms)
        self.task_budget = max(1, task_budget)
        self.db_rollback_alert_threshold = 3
        self.lua_script_path = lua_script_path
        self.lua_command = lua_command.strip()
        self.drift_mode = drift_mode

        self._started_at = time.time()
        self._lock = threading.Lock()
        self._stop_event = asyncio.Event()
        self._tcp_server: Optional[asyncio.AbstractServer] = None
        self._udp_transport: Optional[asyncio.DatagramTransport] = None
        self._tick_task: Optional[asyncio.Task] = None
        self._active_tasks: Set[asyncio.Task] = set()

        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS runtime_state (state_key TEXT PRIMARY KEY, state_value TEXT NOT NULL)"
        )
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS thread_routes (room_key TEXT PRIMARY KEY, thread_id INTEGER NOT NULL)"
        )
        self._conn.commit()

        ping_cls, pong_cls = build_protobuf_models()
        self._Ping = ping_cls
        self._Pong = pong_cls
        self._protobuf_enabled = ping_cls is not None and pong_cls is not None
        if self._protobuf_enabled:
            self.protobuf_request = ping_cls(payload="foo", seq=7, keep=True).SerializeToString()
            self.protobuf_expected_response = pong_cls(payload="FOO", seq=7, ok=True).SerializeToString()
        else:
            self.protobuf_request = b""
            self.protobuf_expected_response = b""

        self._metrics: Dict[str, int] = {
            "accepted_connections": 0,
            "active_connections": 0,
            "max_active_connections": 0,
            "tcp_accept_count": 0,
            "tcp_rx_packet_count": 0,
            "tcp_tx_packet_count": 0,
            "tcp_rx_bytes": 0,
            "tcp_tx_bytes": 0,
            "udp_rx_datagram_count": 0,
            "udp_tx_datagram_count": 0,
            "udp_rx_bytes": 0,
            "udp_tx_bytes": 0,
            "rejected_command_count": 0,
            "backpressure_drop_count": 0,
            "lua_hello_count": 0,
            "lua_hot_reload_count": 0,
            "save_state_count": 0,
            "load_state_count": 0,
            "route_lookup_count": 0,
            "protobuf_request_count": 0,
            "protobuf_response_count": 0,
            "protobuf_unavailable_count": 0,
            "codec_frame_parse_count": 0,
            "codec_frame_build_count": 0,
            "codec_error_count": 0,
            "scenario_flow_count": 0,
            "stability_ping_count": 0,
            "ffi_registered_function_count": 0,
            "ffi_sync_call_count": 0,
            "ffi_async_call_count": 0,
            "ffi_callback_dispatch_count": 0,
            "ffi_async_inflight_count": 0,
            "db_transaction_begin_count": 0,
            "db_commit_count": 0,
            "db_rollback_count": 0,
            "io_poll_count": 0,
            "timer_tick_count": 0,
            "async_schedule_count": 0,
            "async_complete_count": 0,
            "inflight_async_tasks": 0,
            "error_count": 0,
        }
        self._ffi_registry: Dict[str, bool] = {"runtime_hello": True}
        self._metrics["ffi_registered_function_count"] = len(self._ffi_registry)

    def increment_metric(self, key: str, delta: int = 1) -> None:
        with self._lock:
            self._metrics[key] = self._metrics.get(key, 0) + delta

    def add_metric_bytes(self, key: str, byte_count: int) -> None:
        with self._lock:
            self._metrics[key] = self._metrics.get(key, 0) + max(0, byte_count)

    def _update_active_connections(self, delta: int) -> None:
        with self._lock:
            self._metrics["active_connections"] += delta
            current = self._metrics["active_connections"]
            if current > self._metrics["max_active_connections"]:
                self._metrics["max_active_connections"] = current

    def request_stop(self) -> None:
        if not self._stop_event.is_set():
            self._stop_event.set()

    def _read_lua_version_fallback(self) -> str:
        if not self.lua_script_path or (not self.lua_script_path.exists()):
            return "v0"

        content = self.lua_script_path.read_text(encoding="utf-8")
        marker = re.search(r"VERSION:(v[0-9]+)", content)
        if marker:
            return marker.group(1)

        quoted = re.search(r'return\s+"(v[0-9]+)"', content)
        if quoted:
            return quoted.group(1)

        return "v0"

    def _read_lua_version(self) -> str:
        if self.lua_command and self.lua_script_path and self.lua_script_path.exists():
            expression = (
                f"dofile([[{self.lua_script_path}]]) "
                "if type(runtime_hello) == 'function' then io.write(runtime_hello()) else io.write('v0') end"
            )
            try:
                completed = subprocess.run(
                    [self.lua_command, "-e", expression],
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=2.0,
                )
                if completed.returncode == 0 and completed.stdout.strip():
                    return completed.stdout.strip()
            except (OSError, subprocess.SubprocessError):
                pass

        return self._read_lua_version_fallback()

    @staticmethod
    def _next_version(version: str) -> str:
        match = re.fullmatch(r"v([0-9]+)", version)
        if not match:
            return "v1"
        return f"v{int(match.group(1)) + 1}"

    def _hot_reload_lua(self) -> None:
        if not self.lua_script_path:
            return
        if not self.lua_script_path.exists():
            self.lua_script_path.parent.mkdir(parents=True, exist_ok=True)
            self.lua_script_path.write_text(
                "-- VERSION:v1\nfunction runtime_hello()\n  return \"v1\"\nend\n",
                encoding="utf-8",
            )
            return

        content = self.lua_script_path.read_text(encoding="utf-8")
        current = self._read_lua_version_fallback()
        nxt = self._next_version(current)
        replaced = re.sub(r"v[0-9]+", nxt, content)
        if replaced == content:
            replaced = content + f"\n-- VERSION:{nxt}\n"
        self.lua_script_path.write_text(replaced, encoding="utf-8")

    def _run_write_transaction(self, action) -> None:
        with self._lock:
            self._metrics["db_transaction_begin_count"] = self._metrics.get("db_transaction_begin_count", 0) + 1
            try:
                self._conn.execute("BEGIN IMMEDIATE")
                action()
                self._conn.commit()
                self._metrics["db_commit_count"] = self._metrics.get("db_commit_count", 0) + 1
            except Exception:
                self._conn.rollback()
                self._metrics["db_rollback_count"] = self._metrics.get("db_rollback_count", 0) + 1
                self._metrics["error_count"] = self._metrics.get("error_count", 0) + 1
                if self._metrics["db_rollback_count"] >= self.db_rollback_alert_threshold:
                    self._metrics["rejected_command_count"] = self._metrics.get("rejected_command_count", 0) + 1
                raise

    def _register_ffi_function(self, function_name: str) -> bool:
        if not function_name:
            return False
        if function_name in self._ffi_registry:
            return False
        self._ffi_registry[function_name] = True
        self._metrics["ffi_registered_function_count"] = len(self._ffi_registry)
        return True

    def _save_state(self, value: str) -> None:
        def _action() -> None:
            self._conn.execute(
                "INSERT INTO runtime_state(state_key, state_value) VALUES(?, ?) "
                "ON CONFLICT(state_key) DO UPDATE SET state_value=excluded.state_value",
                ("default", value),
            )

        self._run_write_transaction(_action)

    def _load_state(self) -> str:
        with self._lock:
            row = self._conn.execute(
                "SELECT state_value FROM runtime_state WHERE state_key = ?",
                ("default",),
            ).fetchone()
        return row[0] if row else "unset"

    def _delete_state(self) -> None:
        def _action() -> None:
            self._conn.execute("DELETE FROM runtime_state WHERE state_key = ?", ("default",))

        self._run_write_transaction(_action)

    def _route_thread(self, room_key: str) -> int:
        with self._lock:
            row = self._conn.execute(
                "SELECT thread_id FROM thread_routes WHERE room_key = ?",
                (room_key,),
            ).fetchone()
            if row:
                return int(row[0])

        thread_id = int((zlib.crc32(room_key.encode("utf-8")) % self.thread_count) + 1)

        def _action() -> None:
            self._conn.execute(
                "INSERT OR REPLACE INTO thread_routes(room_key, thread_id) VALUES(?, ?)",
                (room_key, thread_id),
            )

        self._run_write_transaction(_action)
        return thread_id

    def _metrics_snapshot(self) -> Dict[str, int | str]:
        with self._lock:
            route_count = self._conn.execute("SELECT COUNT(*) FROM thread_routes").fetchone()[0]
            state_count = self._conn.execute("SELECT COUNT(*) FROM runtime_state").fetchone()[0]
            data = dict(self._metrics)

        data["thread_route_count"] = int(route_count)
        data["persisted_state_count"] = int(state_count)
        data["db_alert_active"] = 1 if int(data.get("db_rollback_count", 0)) >= self.db_rollback_alert_threshold else 0
        data["uptime_ms"] = int((time.time() - self._started_at) * 1000)
        data["runtime_name"] = self.runtime_name
        data["tcp_port"] = self.tcp_port
        data["udp_port"] = self.udp_port
        return data

    def _handle_text_command(self, command: str, transport_kind: str) -> Tuple[str, bool]:
        if command == "M1_CONN_PING":
            return "M1_CONN_PONG", False

        if command == "M1_UDP_PING":
            return "M1_UDP_PONG", False

        if command.startswith("M3_REGISTER_FUNC:"):
            function_name = command.split(":", 1)[1]
            if self._register_ffi_function(function_name):
                return f"M3_REGISTER_OK:{function_name}", False
            self.increment_metric("rejected_command_count")
            return f"M3_REGISTER_FAIL:{function_name}", False

        if command == "M3_LUA_HELLO":
            self.increment_metric("ffi_sync_call_count")
            self.increment_metric("lua_hello_count")
            version = self._read_lua_version()
            return f"M3_LUA_ACK:{version}", False

        if command == "M3_LUA_HELLO_ASYNC":
            self.increment_metric("ffi_async_call_count")
            self.increment_metric("ffi_async_inflight_count")
            version = self._read_lua_version()
            self.increment_metric("ffi_callback_dispatch_count")
            self.increment_metric("ffi_async_inflight_count", -1)
            return f"M3_LUA_ASYNC_ACK:{version}", False

        if command == "M3_HOT_RELOAD":
            self.increment_metric("lua_hot_reload_count")
            self._hot_reload_lua()
            return "M3_HOT_RELOAD_OK", False

        if command.startswith("M4_SAVE_STATE:"):
            value = command.split(":", 1)[1]
            self.increment_metric("save_state_count")
            self._save_state(value)
            return f"M4_SAVE_OK:{value}", False

        if command == "M4_LOAD_STATE":
            self.increment_metric("load_state_count")
            value = self._load_state()
            return f"M4_LOAD_OK:{value}", False

        if command == "M4_DELETE_STATE":
            self._delete_state()
            return "M4_DELETE_OK", False

        if command == "M4_DB_HEALTH":
            metrics = self._metrics_snapshot()
            if int(metrics.get("db_alert_active", 0)) > 0:
                return "M4_DB_ALERT", False
            return "M4_DB_HEALTHY", False

        if command.startswith("M4_ROUTE_THREAD:"):
            room_key = command.split(":", 1)[1]
            self.increment_metric("route_lookup_count")
            thread_id = self._route_thread(room_key)
            if self.drift_mode == "route":
                thread_id = thread_id + 1
            return f"M4_ROUTE_OK:thread-{thread_id}", False

        if command == "M5_FLOW_ROOM":
            self.increment_metric("scenario_flow_count")
            if self.drift_mode == "flow":
                return "M5_FLOW_FAIL", False
            return "M5_FLOW_OK", False

        if command == "M6_STABILITY":
            self.increment_metric("stability_ping_count")
            return "M6_OK", False

        if command == "__METRICS__":
            return json.dumps(self._metrics_snapshot(), separators=(",", ":")), False

        if command == "__STOP__":
            self.request_stop()
            return "__STOP_OK__", True

        self.increment_metric("rejected_command_count")
        return f"ERR_UNKNOWN_{transport_kind.upper()}", False

    def _handle_protobuf(self, payload: bytes) -> bytes:
        self.increment_metric("codec_frame_parse_count")
        if not self._protobuf_enabled:
            self.increment_metric("protobuf_unavailable_count")
            self.increment_metric("rejected_command_count")
            self.increment_metric("codec_error_count")
            return b""

        self.increment_metric("protobuf_request_count")
        ping = self._Ping()
        try:
            ping.ParseFromString(payload)
        except Exception:
            self.increment_metric("rejected_command_count")
            self.increment_metric("codec_error_count")
            return b""

        if ping.payload != "foo" or int(ping.seq) != 7 or (not bool(ping.keep)):
            self.increment_metric("rejected_command_count")
            self.increment_metric("codec_error_count")
            return b""

        response = self._Pong(payload=ping.payload.upper(), seq=ping.seq, ok=True).SerializeToString()
        if self.drift_mode == "protobuf":
            response = self._Pong(payload=ping.payload.lower(), seq=ping.seq, ok=True).SerializeToString()
        self.increment_metric("protobuf_response_count")
        self.increment_metric("codec_frame_build_count")
        return response

    def _can_schedule(self) -> bool:
        with self._lock:
            inflight = self._metrics.get("inflight_async_tasks", 0)
            if inflight >= self.task_budget:
                return False
            self._metrics["inflight_async_tasks"] = inflight + 1
            self._metrics["async_schedule_count"] = self._metrics.get("async_schedule_count", 0) + 1
            return True

    def _mark_task_complete(self) -> None:
        with self._lock:
            self._metrics["inflight_async_tasks"] = max(0, self._metrics.get("inflight_async_tasks", 1) - 1)
            self._metrics["async_complete_count"] = self._metrics.get("async_complete_count", 0) + 1

    def _schedule(self, coro) -> Optional[asyncio.Task]:
        if not self._can_schedule():
            self.increment_metric("backpressure_drop_count")
            self.increment_metric("rejected_command_count")
            return None

        async def _runner():
            result = None
            try:
                result = await coro
            except Exception:
                self.increment_metric("error_count")
                result = False
            finally:
                self._mark_task_complete()
            return result

        task = asyncio.create_task(_runner())
        self._active_tasks.add(task)
        task.add_done_callback(lambda t: self._active_tasks.discard(t))
        return task

    async def _process_tcp_text_command(self, command: str, writer: asyncio.StreamWriter) -> bool:
        self.increment_metric("tcp_rx_packet_count")
        response, should_close = self._handle_text_command(command, "tcp")
        payload = (response + "\n").encode("utf-8")
        if len(payload) > 65536:
            self.increment_metric("codec_error_count")
            self.increment_metric("rejected_command_count")
            payload = b"ERR_CODEC_FRAME_TOO_LARGE\n"
            should_close = False
        self.increment_metric("codec_frame_build_count")
        writer.write(payload)
        await writer.drain()
        self.increment_metric("tcp_tx_packet_count")
        self.add_metric_bytes("tcp_tx_bytes", len(payload))
        return should_close

    async def _handle_tcp_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.increment_metric("accepted_connections")
        self.increment_metric("tcp_accept_count")
        self._update_active_connections(+1)
        try:
            while True:
                first = await reader.read(1)
                if not first:
                    break
                self.add_metric_bytes("tcp_rx_bytes", 1)

                first_byte = first[0]
                if self._protobuf_enabled and self.protobuf_request and first_byte == self.protobuf_request[0]:
                    needed = len(self.protobuf_request) - 1
                    rest = await reader.readexactly(needed) if needed > 0 else b""
                    self.add_metric_bytes("tcp_rx_bytes", len(rest))
                    self.increment_metric("tcp_rx_packet_count")
                    payload = first + rest
                    response = self._handle_protobuf(payload)
                    if response:
                        writer.write(response)
                        await writer.drain()
                        self.increment_metric("tcp_tx_packet_count")
                        self.add_metric_bytes("tcp_tx_bytes", len(response))
                    break

                line = await reader.readline()
                self.add_metric_bytes("tcp_rx_bytes", len(line))
                command_bytes = first + line
                self.increment_metric("codec_frame_parse_count")
                if len(command_bytes) > 2048:
                    self.increment_metric("codec_error_count")
                    self.increment_metric("rejected_command_count")
                    payload = b"ERR_CODEC_COMMAND_TOO_LARGE\n"
                    writer.write(payload)
                    await writer.drain()
                    self.increment_metric("tcp_tx_packet_count")
                    self.add_metric_bytes("tcp_tx_bytes", len(payload))
                    continue
                command = command_bytes.decode("utf-8", errors="replace").strip("\r\n")
                task = self._schedule(self._process_tcp_text_command(command, writer))
                if task is None:
                    payload = b"ERR_BACKPRESSURE\n"
                    writer.write(payload)
                    await writer.drain()
                    self.increment_metric("tcp_tx_packet_count")
                    self.add_metric_bytes("tcp_tx_bytes", len(payload))
                    continue
                should_close = await task
                if should_close:
                    break
        except asyncio.IncompleteReadError:
            self.increment_metric("rejected_command_count")
        except Exception:
            self.increment_metric("error_count")
            self.increment_metric("rejected_command_count")
        finally:
            self._update_active_connections(-1)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _process_udp_payload(
        self,
        data: bytes,
        addr,
        transport: asyncio.DatagramTransport,
    ) -> None:
        self.increment_metric("codec_frame_parse_count")
        if self._protobuf_enabled and self.protobuf_request and data[:1] == self.protobuf_request[:1]:
            response = self._handle_protobuf(data)
            if response:
                transport.sendto(response, addr)
                self.increment_metric("udp_tx_datagram_count")
                self.add_metric_bytes("udp_tx_bytes", len(response))
            return

        if len(data) > 2048:
            self.increment_metric("codec_error_count")
            self.increment_metric("rejected_command_count")
            payload = b"ERR_CODEC_COMMAND_TOO_LARGE\n"
            transport.sendto(payload, addr)
            self.increment_metric("udp_tx_datagram_count")
            self.add_metric_bytes("udp_tx_bytes", len(payload))
            return

        command = data.decode("utf-8", errors="replace").strip("\r\n")
        response, _ = self._handle_text_command(command, "udp")
        payload = (response + "\n").encode("utf-8")
        self.increment_metric("codec_frame_build_count")
        transport.sendto(payload, addr)
        self.increment_metric("udp_tx_datagram_count")
        self.add_metric_bytes("udp_tx_bytes", len(payload))

    def on_udp_datagram(self, data: bytes, addr, transport: asyncio.DatagramTransport) -> None:
        self.increment_metric("udp_rx_datagram_count")
        self.add_metric_bytes("udp_rx_bytes", len(data))
        task = self._schedule(self._process_udp_payload(data, addr, transport))
        if task is None:
            payload = b"ERR_BACKPRESSURE\n"
            transport.sendto(payload, addr)
            self.increment_metric("udp_tx_datagram_count")
            self.add_metric_bytes("udp_tx_bytes", len(payload))

    async def _tick_loop(self) -> None:
        interval = self.tick_interval_ms / 1000.0
        while not self._stop_event.is_set():
            await asyncio.sleep(interval)
            self.increment_metric("timer_tick_count")
            self.increment_metric("io_poll_count")

    async def run(self) -> None:
        self._tcp_server = await asyncio.start_server(self._handle_tcp_client, self.host, self.tcp_port)
        loop = asyncio.get_running_loop()
        udp_transport, _ = await loop.create_datagram_endpoint(
            lambda: RuntimeHostUdpProtocol(self),
            local_addr=(self.host, self.udp_port),
        )
        self._udp_transport = udp_transport
        self._tick_task = asyncio.create_task(self._tick_loop())

        print(
            "runtime_host_server_ready "
            f"host={self.host} tcp_port={self.tcp_port} udp_port={self.udp_port} runtime={self.runtime_name}",
            flush=True,
        )

        async with self._tcp_server:
            await self._stop_event.wait()

        await self.shutdown()

    async def shutdown(self) -> None:
        if self._tick_task is not None:
            self._tick_task.cancel()
            try:
                await self._tick_task
            except asyncio.CancelledError:
                pass

        if self._tcp_server is not None:
            self._tcp_server.close()
            await self._tcp_server.wait_closed()

        if self._udp_transport is not None:
            self._udp_transport.close()

        if self._active_tasks:
            await asyncio.wait(self._active_tasks, timeout=2.0)

        with self._lock:
            self._conn.commit()
            self._conn.close()


def register_signal_handlers(host: RuntimeHost) -> None:
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, host.request_stop)
        except (NotImplementedError, RuntimeError, ValueError):
            # Windows Proactor loop may not support signal handlers.
            pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deployable runtime host server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, required=True)
    parser.add_argument("--udp-port", type=int, default=0)
    parser.add_argument("--runtime-name", default="sengoo")
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--thread-count", type=int, default=4)
    parser.add_argument("--tick-interval-ms", type=int, default=50)
    parser.add_argument("--task-budget", type=int, default=256)
    parser.add_argument("--lua-script-path", default="")
    parser.add_argument("--lua-command", default="")
    parser.add_argument("--drift-mode", choices=["none", "route", "flow", "protobuf"], default="none")
    return parser.parse_args()


async def main_async() -> None:
    args = parse_args()
    tcp_port = int(args.tcp_port)
    udp_port = int(args.udp_port) if int(args.udp_port) > 0 else tcp_port + 1
    lua_script = Path(args.lua_script_path) if args.lua_script_path else None
    host = RuntimeHost(
        host=args.host,
        tcp_port=tcp_port,
        udp_port=udp_port,
        runtime_name=args.runtime_name,
        db_path=Path(args.db_path),
        thread_count=int(args.thread_count),
        tick_interval_ms=int(args.tick_interval_ms),
        task_budget=int(args.task_budget),
        lua_script_path=lua_script,
        lua_command=args.lua_command,
        drift_mode=args.drift_mode,
    )
    register_signal_handlers(host)
    await host.run()


def main() -> None:
    try:
        asyncio.run(main_async())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
