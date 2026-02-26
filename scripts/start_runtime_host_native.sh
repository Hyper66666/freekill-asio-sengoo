#!/usr/bin/env bash
set -euo pipefail

BINARY_PATH="${1:-release/native/linux-x64/bin/freekill-asio-sengoo-runtime}"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "native runtime binary not found: $BINARY_PATH" >&2
  exit 1
fi

chmod +x "$BINARY_PATH"
"$BINARY_PATH"
EXIT_CODE=$?
echo "NATIVE_RUNTIME_EXIT=$EXIT_CODE"
echo "NATIVE_RUNTIME_BINARY=$(cd "$(dirname "$BINARY_PATH")" && pwd)/$(basename "$BINARY_PATH")"
exit "$EXIT_CODE"
