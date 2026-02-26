param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$ConfigJsonPath = "",

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
  [string]$DriftMode = "none",

  [Parameter(Mandatory = $false)]
  [switch]$PrintEffectiveConfig
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$serverPath = "scripts/runtime_host_server.py"
if (-not (Test-Path $serverPath)) {
  throw "missing runtime host server script: $serverPath"
}

$useConfigFile = -not [string]::IsNullOrWhiteSpace($ConfigJsonPath)
if ($useConfigFile -and -not (Test-Path $ConfigJsonPath)) {
  throw "ConfigJsonPath not found: $ConfigJsonPath"
}

$args = @($serverPath)
if ($useConfigFile) {
  $args += @("--config-json", $ConfigJsonPath)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("ListenHost")) {
  $args += @("--host", $ListenHost)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("TcpPort")) {
  if ($TcpPort -le 0 -or $TcpPort -gt 65535) {
    throw "TcpPort out of range: $TcpPort"
  }
  $args += @("--tcp-port", $TcpPort)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("UdpPort")) {
  if ($UdpPort -le 0 -or $UdpPort -gt 65535) {
    throw "UdpPort out of range: $UdpPort"
  }
  $args += @("--udp-port", $UdpPort)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("DbPath")) {
  $dbParent = Split-Path -Parent $DbPath
  if (-not [string]::IsNullOrWhiteSpace($dbParent) -and -not (Test-Path $dbParent)) {
    New-Item -ItemType Directory -Force -Path $dbParent | Out-Null
  }
  $args += @("--db-path", $DbPath)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("ThreadCount")) {
  $args += @("--thread-count", $ThreadCount)
}
if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("TickIntervalMs")) {
  $args += @("--tick-interval-ms", $TickIntervalMs)
}
if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("TaskBudget")) {
  $args += @("--task-budget", $TaskBudget)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("LuaScriptPath")) {
  $luaParent = Split-Path -Parent $LuaScriptPath
  if (-not [string]::IsNullOrWhiteSpace($luaParent) -and -not (Test-Path $luaParent)) {
    New-Item -ItemType Directory -Force -Path $luaParent | Out-Null
  }
  if (-not (Test-Path $LuaScriptPath)) {
    "-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $LuaScriptPath -Encoding UTF8
  }
  $args += @("--lua-script-path", $LuaScriptPath)
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("LuaCommand")) {
  if (-not [string]::IsNullOrWhiteSpace($LuaCommand)) {
    $args += @("--lua-command", $LuaCommand)
  }
}

if (-not $useConfigFile -or $PSBoundParameters.ContainsKey("DriftMode")) {
  $args += @("--drift-mode", $DriftMode)
}

if ($PrintEffectiveConfig) {
  $args += "--print-effective-config"
}

& $PythonExe @args
exit $LASTEXITCODE
