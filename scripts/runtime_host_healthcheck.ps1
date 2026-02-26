param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$EndpointHost = "127.0.0.1",

  [Parameter(Mandatory = $true)]
  [int]$TcpPort,

  [Parameter(Mandatory = $false)]
  [int]$UdpPort = 0,

  [Parameter(Mandatory = $false)]
  [switch]$RequireUdp,

  [Parameter(Mandatory = $false)]
  [int]$MaxErrorCount = -1,

  [Parameter(Mandatory = $false)]
  [int]$MinTimerTickCount = -1,

  [Parameter(Mandatory = $false)]
  [int]$MinIoPollCount = -1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$healthScript = "scripts/runtime_host_healthcheck.py"
if (-not (Test-Path $healthScript)) {
  throw "healthcheck script not found: $healthScript"
}

$args = @(
  $healthScript,
  "--host", $EndpointHost,
  "--tcp-port", $TcpPort,
  "--json-output"
)
if ($UdpPort -gt 0) {
  $args += @("--udp-port", $UdpPort)
}
if ($RequireUdp) {
  $args += "--require-udp"
}
if ($MaxErrorCount -ge 0) {
  $args += @("--max-error-count", $MaxErrorCount)
}
if ($MinTimerTickCount -ge 0) {
  $args += @("--min-timer-tick-count", $MinTimerTickCount)
}
if ($MinIoPollCount -ge 0) {
  $args += @("--min-io-poll-count", $MinIoPollCount)
}

& $PythonExe @args
exit $LASTEXITCODE
