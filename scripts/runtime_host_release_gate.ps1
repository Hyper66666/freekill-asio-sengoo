param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [int]$SoakDurationSeconds = 60,

  [Parameter(Mandatory = $false)]
  [string]$AcceptanceScriptPath = "scripts/runtime_host_acceptance.ps1",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_release_gate.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

if (-not (Test-Path $AcceptanceScriptPath)) {
  throw "acceptance script not found: $AcceptanceScriptPath"
}

$startUtc = (Get-Date).ToUniversalTime()
powershell -NoProfile -ExecutionPolicy Bypass -File $AcceptanceScriptPath `
  -SgcPath $SgcPath `
  -IncludeWatchdogSmoke `
  -IncludeSoak `
  -SoakDurationSeconds $SoakDurationSeconds | Out-Null

if ($LASTEXITCODE -ne 0) {
  throw "release gate failed: acceptance returned non-zero"
}

$acceptancePath = ".tmp/runtime_host/runtime_host_acceptance.json"
if (-not (Test-Path $acceptancePath)) {
  throw "release gate failed: missing acceptance report $acceptancePath"
}

$acceptance = Get-Content -Raw $acceptancePath | ConvertFrom-Json
$overallOk = [bool]$acceptance.overall_ok
$gate = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  started_at_utc = $startUtc.ToString("o")
  overall_ok = $overallOk
  soak_duration_seconds = $SoakDurationSeconds
  acceptance_report_path = (Resolve-Path $acceptancePath).Path
  acceptance = $acceptance
}

Ensure-ParentDir $OutputPath
$gate | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("RELEASE_GATE_OK={0}" -f $overallOk)
Write-Output ("RELEASE_GATE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
