param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [string]$AckReplayScriptPath = "scripts/runtime_host_ack_replay.ps1",

  [Parameter(Mandatory = $false)]
  [string]$AckReplayReportPath = ".tmp/runtime_host/ack_replay_report.json",

  [Parameter(Mandatory = $false)]
  [string]$LiveSmokeScriptPath = "scripts/runtime_host_live_smoke.ps1",

  [Parameter(Mandatory = $false)]
  [string]$LiveSmokeReportPath = ".tmp/runtime_host/runtime_host_live_smoke_report.json",

  [Parameter(Mandatory = $false)]
  [string]$ConfigSmokeScriptPath = "scripts/runtime_host_config_smoke.ps1",

  [Parameter(Mandatory = $false)]
  [string]$ConfigSmokeReportPath = ".tmp/runtime_host/runtime_host_config_smoke_report.json",

  [Parameter(Mandatory = $false)]
  [switch]$IncludeSoak,

  [Parameter(Mandatory = $false)]
  [string]$SoakScriptPath = "scripts/runtime_host_soak.ps1",

  [Parameter(Mandatory = $false)]
  [string]$SoakReportPath = ".tmp/runtime_host/runtime_host_soak_report.json",

  [Parameter(Mandatory = $false)]
  [int]$SoakDurationSeconds = 20,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_acceptance.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

if (-not (Test-Path $SgcPath)) {
  throw "sgc not found: $SgcPath"
}
if (-not (Test-Path $AckReplayScriptPath)) {
  throw "ack replay script not found: $AckReplayScriptPath"
}
if (-not (Test-Path $LiveSmokeScriptPath)) {
  throw "live smoke script not found: $LiveSmokeScriptPath"
}
if (-not (Test-Path $ConfigSmokeScriptPath)) {
  throw "config smoke script not found: $ConfigSmokeScriptPath"
}
if ($IncludeSoak -and -not (Test-Path $SoakScriptPath)) {
  throw "soak script not found: $SoakScriptPath"
}

$targets = @(
  "src/main.sg",
  "src/network_sg/server_socket.sg",
  "src/core_sg/stability.sg",
  "src/ffi_bridge_sg/c_wrapper.sg",
  "src/ffi_bridge_sg/rpc_bridge.sg",
  "src/ffi_bridge_sg/lua_ffi.sg",
  "src/codec_sg/packet_wire.sg",
  "src/codec_sg/packet_codec.sg",
  "src/server_sg/sqlite_store.sg",
  "src/server_sg/runtime_host.sg",
  "src/server_sg/runtime_host_adapter.sg"
)

$sgcResults = @()
foreach ($target in $targets) {
  if (-not (Test-Path $target)) {
    throw "missing target: $target"
  }

  & $SgcPath check $target
  $code = $LASTEXITCODE
  $ok = $code -eq 0
  $sgcResults += [ordered]@{
    target = $target
    ok = $ok
    exit_code = $code
  }

  if (-not $ok) {
    throw "sgc check failed for $target (exit=$code)"
  }
}

powershell -NoProfile -ExecutionPolicy Bypass -File $AckReplayScriptPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "ack replay script failed"
}

if (-not (Test-Path $AckReplayReportPath)) {
  throw "missing ack replay report: $AckReplayReportPath"
}

$ackReport = Get-Content -Raw $AckReplayReportPath | ConvertFrom-Json
$emitted = [int64]$ackReport.totals.emitted
$ackOk = [int64]$ackReport.totals.ack_ok
$ackError = [int64]$ackReport.totals.ack_error
$inflightFinal = [int64]$ackReport.totals.inflight_final
$ackHealthOk = ($emitted -gt 0) -and (($ackOk + $ackError) -le $emitted) -and ($inflightFinal -eq 0)

powershell -NoProfile -ExecutionPolicy Bypass -File $LiveSmokeScriptPath -OutputPath $LiveSmokeReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "runtime host live smoke failed"
}

if (-not (Test-Path $LiveSmokeReportPath)) {
  throw "missing runtime host live smoke report: $LiveSmokeReportPath"
}

$liveSmokeReport = Get-Content -Raw $LiveSmokeReportPath | ConvertFrom-Json
$liveSmokeOk = [bool]$liveSmokeReport.pass

powershell -NoProfile -ExecutionPolicy Bypass -File $ConfigSmokeScriptPath -OutputPath $ConfigSmokeReportPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "runtime host config smoke failed"
}

if (-not (Test-Path $ConfigSmokeReportPath)) {
  throw "missing runtime host config smoke report: $ConfigSmokeReportPath"
}

$configSmokeReport = Get-Content -Raw $ConfigSmokeReportPath | ConvertFrom-Json
$configSmokeOk = [bool]$configSmokeReport.pass

$soakExecuted = [bool]$IncludeSoak
$soakOk = $true
$soakReportResolvedPath = ""
if ($IncludeSoak) {
  powershell -NoProfile -ExecutionPolicy Bypass -File $SoakScriptPath `
    -DurationSeconds $SoakDurationSeconds `
    -OutputPath $SoakReportPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "runtime host soak failed"
  }
  if (-not (Test-Path $SoakReportPath)) {
    throw "missing runtime host soak report: $SoakReportPath"
  }
  $soakReport = Get-Content -Raw $SoakReportPath | ConvertFrom-Json
  $soakOk = [bool]$soakReport.pass
  $soakReportResolvedPath = (Resolve-Path $SoakReportPath).Path
}

$overallOk = $ackHealthOk -and $liveSmokeOk -and $configSmokeOk -and $soakOk

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_ok = $overallOk
  sgc_checks = $sgcResults
  ack_replay = [ordered]@{
    emitted = $emitted
    ack_ok = $ackOk
    ack_error = $ackError
    inflight_final = $inflightFinal
    health_ok = $ackHealthOk
    report_path = (Resolve-Path $AckReplayReportPath).Path
  }
  live_smoke = [ordered]@{
    pass = $liveSmokeOk
    report_path = (Resolve-Path $LiveSmokeReportPath).Path
    tcp_port = [int64]$liveSmokeReport.tcp_port
    udp_port = [int64]$liveSmokeReport.udp_port
  }
  config_smoke = [ordered]@{
    pass = $configSmokeOk
    report_path = (Resolve-Path $ConfigSmokeReportPath).Path
    runtime_name = [string]$configSmokeReport.runtime_name
    tcp_port = [int64]$configSmokeReport.tcp_port
    udp_port = [int64]$configSmokeReport.udp_port
  }
  soak = [ordered]@{
    executed = $soakExecuted
    pass = $soakOk
    report_path = $soakReportResolvedPath
    duration_seconds = $SoakDurationSeconds
  }
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("ACCEPTANCE_OK={0}" -f $overallOk)
Write-Output ("ACCEPTANCE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
