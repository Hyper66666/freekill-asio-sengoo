param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [string]$AckReplayScriptPath = "scripts/runtime_host_ack_replay.ps1",

  [Parameter(Mandatory = $false)]
  [string]$AckReplayReportPath = ".tmp/runtime_host/ack_replay_report.json",

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

$targets = @(
  "src/main.sg",
  "src/network_sg/server_socket.sg",
  "src/core_sg/stability.sg",
  "src/ffi_bridge_sg/c_wrapper.sg",
  "src/ffi_bridge_sg/rpc_bridge.sg",
  "src/codec_sg/packet_wire.sg",
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

$overallOk = $ackHealthOk

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
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("ACCEPTANCE_OK={0}" -f $overallOk)
Write-Output ("ACCEPTANCE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
