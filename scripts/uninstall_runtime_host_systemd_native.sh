#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="freekill-runtime-host-native"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" != "0" ]]; then
  echo "must run as root" >&2
  exit 1
fi

UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true

if [[ -f "$UNIT_PATH" ]]; then
  rm -f "$UNIT_PATH"
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

echo "NATIVE_SYSTEMD_SERVICE_UNINSTALLED"
echo "SERVICE_NAME=$SERVICE_NAME"
