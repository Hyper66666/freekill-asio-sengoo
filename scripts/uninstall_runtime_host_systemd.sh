#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="freekill-runtime-host"
if [[ $# -ge 2 && "$1" == "--service-name" ]]; then
  SERVICE_NAME="$2"
  shift 2
fi

if [[ "$(id -u)" != "0" ]]; then
  echo "must run as root" >&2
  exit 1
fi

UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_PATH="/etc/default/${SERVICE_NAME}"

if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  systemctl disable --now "$SERVICE_NAME" || true
fi

if [[ -f "$UNIT_PATH" ]]; then
  rm -f "$UNIT_PATH"
fi
if [[ -f "$ENV_PATH" ]]; then
  rm -f "$ENV_PATH"
fi

systemctl daemon-reload
echo "SYSTEMD_SERVICE_REMOVED"
echo "SERVICE_NAME=$SERVICE_NAME"
