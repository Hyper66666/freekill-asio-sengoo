#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BIN_A="$SCRIPT_DIR/../bin/freekill-asio-sengoo-runtime"
DEFAULT_BIN_B="$SCRIPT_DIR/../release/native/linux-x64/bin/freekill-asio-sengoo-runtime"
BINARY_PATH="${1:-}"
if [[ -z "$BINARY_PATH" ]]; then
  if [[ -f "$DEFAULT_BIN_A" ]]; then
    BINARY_PATH="$DEFAULT_BIN_A"
  else
    BINARY_PATH="$DEFAULT_BIN_B"
  fi
fi

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
