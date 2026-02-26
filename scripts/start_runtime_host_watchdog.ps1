param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$ConfigJsonPath = "scripts/runtime_host.config.example.json",

  [Parameter(Mandatory = $false)]
  [string]$HealthHost = "127.0.0.1",

  [Parameter(Mandatory = $false)]
  [int]$HealthTcpPort = 0,

  [Parameter(Mandatory = $false)]
  [int]$HealthUdpPort = 0,

  [Parameter(Mandatory = $false)]
  [switch]$RequireUdpHealth,

  [Parameter(Mandatory = $false)]
  [int]$MaxRestarts = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$watchdogPath = "scripts/runtime_host_watchdog.py"
$serverPath = "scripts/runtime_host_server.py"
if (-not (Test-Path $watchdogPath)) {
  throw "watchdog script not found: $watchdogPath"
}
if (-not (Test-Path $serverPath)) {
  throw "server script not found: $serverPath"
}
if (-not (Test-Path $ConfigJsonPath)) {
  throw "config json not found: $ConfigJsonPath"
}

$tmpRoot = ".tmp/runtime_host_service"
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$statusPath = Join-Path $tmpRoot "watchdog_status.json"
$eventLogPath = Join-Path $tmpRoot "watchdog_events.jsonl"
$stdoutLogPath = Join-Path $tmpRoot "watchdog_server.stdout.log"
$stderrLogPath = Join-Path $tmpRoot "watchdog_server.stderr.log"

$args = @(
  $watchdogPath,
  "--python-exe", $PythonExe,
  "--server-script", $serverPath,
  "--config-json", $ConfigJsonPath,
  "--health-host", $HealthHost,
  "--status-path", $statusPath,
  "--event-log-path", $eventLogPath,
  "--stdout-log-path", $stdoutLogPath,
  "--stderr-log-path", $stderrLogPath
)
if ($HealthTcpPort -gt 0) {
  $args += @("--health-tcp-port", $HealthTcpPort)
}
if ($HealthUdpPort -gt 0) {
  $args += @("--health-udp-port", $HealthUdpPort)
}
if ($RequireUdpHealth) {
  $args += "--require-udp-health"
}
if ($MaxRestarts -gt 0) {
  $args += @("--max-restarts", $MaxRestarts)
}

& $PythonExe @args
exit $LASTEXITCODE
