#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="freekill-runtime-host"
PYTHON_EXE="python3"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_JSON=""
HEALTH_HOST="127.0.0.1"
HEALTH_TCP_PORT="0"
HEALTH_UDP_PORT="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name)
      SERVICE_NAME="$2"
      shift 2
      ;;
    --python-exe)
      PYTHON_EXE="$2"
      shift 2
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --config-json)
      CONFIG_JSON="$2"
      shift 2
      ;;
    --health-host)
      HEALTH_HOST="$2"
      shift 2
      ;;
    --health-tcp-port)
      HEALTH_TCP_PORT="$2"
      shift 2
      ;;
    --health-udp-port)
      HEALTH_UDP_PORT="$2"
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
if [[ -z "$CONFIG_JSON" ]]; then
  CONFIG_JSON="$REPO_ROOT/scripts/runtime_host.config.example.json"
fi
if [[ ! -f "$CONFIG_JSON" ]]; then
  echo "config json not found: $CONFIG_JSON" >&2
  exit 1
fi
if [[ ! -f "$REPO_ROOT/scripts/runtime_host_watchdog.py" ]]; then
  echo "watchdog script not found: $REPO_ROOT/scripts/runtime_host_watchdog.py" >&2
  exit 1
fi
if [[ ! -f "$REPO_ROOT/scripts/runtime_host_server.py" ]]; then
  echo "server script not found: $REPO_ROOT/scripts/runtime_host_server.py" >&2
  exit 1
fi

RUNTIME_TMP="$REPO_ROOT/.tmp/runtime_host_service"
mkdir -p "$RUNTIME_TMP"

ENV_PATH="/etc/default/${SERVICE_NAME}"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

cat >"$ENV_PATH" <<EOF
PYTHON_EXE="$PYTHON_EXE"
REPO_ROOT="$REPO_ROOT"
CONFIG_JSON="$CONFIG_JSON"
HEALTH_HOST="$HEALTH_HOST"
HEALTH_TCP_PORT="$HEALTH_TCP_PORT"
HEALTH_UDP_PORT="$HEALTH_UDP_PORT"
STATUS_PATH="$RUNTIME_TMP/watchdog_status.json"
EVENT_LOG_PATH="$RUNTIME_TMP/watchdog_events.jsonl"
STDOUT_LOG_PATH="$RUNTIME_TMP/watchdog_server.stdout.log"
STDERR_LOG_PATH="$RUNTIME_TMP/watchdog_server.stderr.log"
EOF

cat >"$UNIT_PATH" <<'EOF'
[Unit]
Description=FreeKill Runtime Host Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%E{REPO_ROOT}
EnvironmentFile=%E{ENV_PATH_PLACEHOLDER}
ExecStart=/usr/bin/env bash -lc '"${PYTHON_EXE}" "${REPO_ROOT}/scripts/runtime_host_watchdog.py" --python-exe "${PYTHON_EXE}" --server-script "${REPO_ROOT}/scripts/runtime_host_server.py" --config-json "${CONFIG_JSON}" --health-host "${HEALTH_HOST}" --health-tcp-port "${HEALTH_TCP_PORT}" --health-udp-port "${HEALTH_UDP_PORT}" --status-path "${STATUS_PATH}" --event-log-path "${EVENT_LOG_PATH}" --stdout-log-path "${STDOUT_LOG_PATH}" --stderr-log-path "${STDERR_LOG_PATH}"'
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=20
NoNewPrivileges=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Replace placeholders after heredoc to avoid shell interpolation issues.
sed -i "s|%E{REPO_ROOT}|$REPO_ROOT|g" "$UNIT_PATH"
sed -i "s|%E{ENV_PATH_PLACEHOLDER}|$ENV_PATH|g" "$UNIT_PATH"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl status --no-pager --lines=20 "$SERVICE_NAME" || true

echo "SYSTEMD_SERVICE_INSTALLED"
echo "SERVICE_NAME=$SERVICE_NAME"
echo "UNIT_PATH=$UNIT_PATH"
echo "ENV_PATH=$ENV_PATH"
