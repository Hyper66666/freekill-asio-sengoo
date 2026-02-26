param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$ListenHost = "0.0.0.0",

  [Parameter(Mandatory = $false)]
  [int]$TcpPort = 9527,

  [Parameter(Mandatory = $false)]
  [int]$UdpPort = 9528,

  [Parameter(Mandatory = $false)]
  [string]$DbPath = ".tmp/runtime_host/runtime.sqlite",

  [Parameter(Mandatory = $false)]
  [int]$ThreadCount = 4,

  [Parameter(Mandatory = $false)]
  [int]$TickIntervalMs = 50,

  [Parameter(Mandatory = $false)]
  [int]$TaskBudget = 256,

  [Parameter(Mandatory = $false)]
  [string]$LuaScriptPath = ".tmp/runtime_host/runtime.lua",

  [Parameter(Mandatory = $false)]
  [string]$LuaCommand = "",

  [Parameter(Mandatory = $false)]
  [ValidateSet("none", "route", "flow", "protobuf")]
  [string]$DriftMode = "none"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$serverPath = "scripts/runtime_host_server.py"
if (-not (Test-Path $serverPath)) {
  throw "missing runtime host server script: $serverPath"
}

if ($TcpPort -le 0 -or $TcpPort -gt 65535) {
  throw "TcpPort out of range: $TcpPort"
}
if ($UdpPort -le 0 -or $UdpPort -gt 65535) {
  throw "UdpPort out of range: $UdpPort"
}

$dbParent = Split-Path -Parent $DbPath
if (-not [string]::IsNullOrWhiteSpace($dbParent) -and -not (Test-Path $dbParent)) {
  New-Item -ItemType Directory -Force -Path $dbParent | Out-Null
}

$luaParent = Split-Path -Parent $LuaScriptPath
if (-not [string]::IsNullOrWhiteSpace($luaParent) -and -not (Test-Path $luaParent)) {
  New-Item -ItemType Directory -Force -Path $luaParent | Out-Null
}
if (-not (Test-Path $LuaScriptPath)) {
  "-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $LuaScriptPath -Encoding UTF8
}

$args = @(
  $serverPath,
  "--host", $ListenHost,
  "--tcp-port", $TcpPort,
  "--udp-port", $UdpPort,
  "--db-path", $DbPath,
  "--thread-count", $ThreadCount,
  "--tick-interval-ms", $TickIntervalMs,
  "--task-budget", $TaskBudget,
  "--lua-script-path", $LuaScriptPath,
  "--drift-mode", $DriftMode
)
if (-not [string]::IsNullOrWhiteSpace($LuaCommand)) {
  $args += @("--lua-command", $LuaCommand)
}

& $PythonExe @args
exit $LASTEXITCODE
