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
if [[ "$EXIT_CODE" -eq 0 ]]; then
  echo "NATIVE_HEALTH_OK=true"
  echo "NATIVE_HEALTH_EXIT=$EXIT_CODE"
  exit 0
fi

echo "NATIVE_HEALTH_OK=false"
echo "NATIVE_HEALTH_EXIT=$EXIT_CODE"
exit 1
