#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="freekill-runtime-host-native"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --binary-path)
      BINARY_PATH="$2"
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

REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
if [[ -z "$BINARY_PATH" ]]; then
  if [[ -f "$REPO_ROOT/bin/freekill-asio-sengoo-runtime" ]]; then
    BINARY_PATH="$REPO_ROOT/bin/freekill-asio-sengoo-runtime"
  else
    BINARY_PATH="$REPO_ROOT/release/native/linux-x64/bin/freekill-asio-sengoo-runtime"
  fi
fi
if [[ ! -f "$BINARY_PATH" ]]; then
  echo "native runtime binary not found: $BINARY_PATH" >&2
  exit 1
fi

chmod +x "$BINARY_PATH"

UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
cat >"$UNIT_PATH" <<EOF
[Unit]
Description=FreeKill Native Runtime Host
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$REPO_ROOT
ExecStart=$BINARY_PATH
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=20
NoNewPrivileges=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl status --no-pager --lines=20 "$SERVICE_NAME" || true

echo "NATIVE_SYSTEMD_SERVICE_INSTALLED"
echo "SERVICE_NAME=$SERVICE_NAME"
echo "UNIT_PATH=$UNIT_PATH"
echo "BINARY_PATH=$BINARY_PATH"
