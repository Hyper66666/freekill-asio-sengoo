#!/usr/bin/env python3
"""Binary protobuf regression check against runtime host endpoints."""

from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path

from google.protobuf import descriptor_pb2
from google.protobuf import descriptor_pool
from google.protobuf import message_factory


def build_protobuf_models():
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
    ping_cls = message_factory.GetMessageClass(pool.FindMessageTypeByName("runtime.Ping"))
    pong_cls = message_factory.GetMessageClass(pool.FindMessageTypeByName("runtime.Pong"))
    return ping_cls, pong_cls


def read_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="protobuf binary regression runner")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--request-hex", required=True)
    parser.add_argument("--expected-response-hex", required=True)
    parser.add_argument("--output-path", required=True)
    parser.add_argument("--timeout-ms", type=int, default=1500)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    ping_cls, pong_cls = build_protobuf_models()

    request_bytes = bytes.fromhex(args.request_hex.strip())
    expected_response = bytes.fromhex(args.expected_response_hex.strip())

    report = {
        "host": args.host,
        "port": args.port,
        "request_hex": request_bytes.hex(),
        "expected_response_hex": expected_response.hex(),
        "pass": False,
        "reason": "",
    }

    try:
        ping = ping_cls()
        ping.ParseFromString(request_bytes)
        if ping.payload != "foo" or int(ping.seq) != 7 or not bool(ping.keep):
            raise RuntimeError("request payload does not match expected Ping schema fixture")

        with socket.create_connection((args.host, int(args.port)), timeout=args.timeout_ms / 1000.0) as sock:
            sock.sendall(request_bytes)
            response = read_exact(sock, len(expected_response))

        pong = pong_cls()
        pong.ParseFromString(response)
        if pong.payload != ping.payload.upper():
            raise RuntimeError("response payload mismatch after schema decode")
        if int(pong.seq) != int(ping.seq):
            raise RuntimeError("response sequence mismatch after schema decode")
        if not bool(pong.ok):
            raise RuntimeError("response ok flag is false")
        if response != expected_response:
            raise RuntimeError(
                f"response bytes mismatch expected={expected_response.hex()} actual={response.hex()}"
            )

        report["response_hex"] = response.hex()
        report["pass"] = True
        report["reason"] = "protobuf schema decode/encode regression passed"
    except Exception as exc:  # pylint: disable=broad-except
        report["reason"] = str(exc)

    output_path = Path(args.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(report, indent=2), encoding="utf-8")

    print(f"protobuf_regression_report={output_path}")
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
