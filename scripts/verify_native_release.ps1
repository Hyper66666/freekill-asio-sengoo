param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [int]$SoakDurationSeconds = 20,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_verify_native_release.json"
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

$startUtc = (Get-Date).ToUniversalTime()

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_native_release.ps1 `
  -SgcPath $SgcPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "verify failed: build_native_release.ps1 returned non-zero"
}

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_acceptance_native.ps1 `
  -SgcPath $SgcPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "verify failed: runtime_host_acceptance_native.ps1 returned non-zero"
}

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/runtime_host_release_gate.ps1 `
  -SgcPath $SgcPath `
  -SoakDurationSeconds $SoakDurationSeconds | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "verify failed: runtime_host_release_gate.ps1 returned non-zero"
}

$acceptancePath = ".tmp/runtime_host/runtime_host_acceptance_native.json"
$gatePath = ".tmp/runtime_host/runtime_host_release_gate.json"
if (-not (Test-Path $acceptancePath)) {
  throw "verify failed: missing acceptance report $acceptancePath"
}
if (-not (Test-Path $gatePath)) {
  throw "verify failed: missing gate report $gatePath"
}

$acceptance = Get-Content -Raw $acceptancePath | ConvertFrom-Json
$gate = Get-Content -Raw $gatePath | ConvertFrom-Json
$overallOk = [bool]$acceptance.overall_ok -and [bool]$gate.overall_ok

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  started_at_utc = $startUtc.ToString("o")
  overall_ok = $overallOk
  soak_duration_seconds = $SoakDurationSeconds
  acceptance_report_path = (Resolve-Path $acceptancePath).Path
  release_gate_report_path = (Resolve-Path $gatePath).Path
  acceptance = $acceptance
  release_gate = $gate
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("VERIFY_NATIVE_RELEASE_OK={0}" -f $overallOk)
Write-Output ("VERIFY_NATIVE_RELEASE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
