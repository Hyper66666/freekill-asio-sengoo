param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [int]$SoakDurationSeconds = 60,

  [Parameter(Mandatory = $false)]
  [string]$NativeAcceptanceScriptPath = "scripts/runtime_host_acceptance_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$LegacyAcceptanceScriptPath = "scripts/runtime_host_acceptance.ps1",

  [Parameter(Mandatory = $false)]
  [switch]$UseLegacyPythonAcceptance,

  [Parameter(Mandatory = $false)]
  [bool]$IncludeNativeSoak = $true,

  [Parameter(Mandatory = $false)]
  [string]$NativeSoakScriptPath = "scripts/runtime_host_soak_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$NativeSoakReportPath = ".tmp/runtime_host/runtime_host_soak_native_report.json",

  [Parameter(Mandatory = $false)]
  [string]$DependencyAuditScriptPath = "scripts/audit_native_release_dependencies.ps1",

  [Parameter(Mandatory = $false)]
  [string]$DependencyAuditReportPath = ".tmp/runtime_host/runtime_host_dependency_audit.json",

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

$startUtc = (Get-Date).ToUniversalTime()
if ($UseLegacyPythonAcceptance) {
  if (-not (Test-Path $LegacyAcceptanceScriptPath)) {
    throw "legacy acceptance script not found: $LegacyAcceptanceScriptPath"
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File $LegacyAcceptanceScriptPath `
    -SgcPath $SgcPath `
    -IncludeWatchdogSmoke `
    -IncludeSoak `
    -SoakDurationSeconds $SoakDurationSeconds | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: legacy acceptance returned non-zero"
  }
} else {
  if (-not (Test-Path $NativeAcceptanceScriptPath)) {
    throw "native acceptance script not found: $NativeAcceptanceScriptPath"
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File $NativeAcceptanceScriptPath `
    -SgcPath $SgcPath | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: native acceptance returned non-zero"
  }
}

$acceptancePath = if ($UseLegacyPythonAcceptance) {
  ".tmp/runtime_host/runtime_host_acceptance.json"
} else {
  ".tmp/runtime_host/runtime_host_acceptance_native.json"
}

if (-not (Test-Path $acceptancePath)) {
  throw "release gate failed: missing acceptance report $acceptancePath"
}

$acceptance = Get-Content -Raw $acceptancePath | ConvertFrom-Json
$dependencyAuditExecuted = -not $UseLegacyPythonAcceptance
$dependencyAuditOk = $true
$dependencyAudit = $null
if ($dependencyAuditExecuted) {
  if (-not (Test-Path $DependencyAuditScriptPath)) {
    throw "dependency audit script not found: $DependencyAuditScriptPath"
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File $DependencyAuditScriptPath `
    -OutputPath $DependencyAuditReportPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: dependency audit returned non-zero"
  }
  if (-not (Test-Path $DependencyAuditReportPath)) {
    throw "release gate failed: missing dependency audit report $DependencyAuditReportPath"
  }
  $dependencyAudit = Get-Content -Raw $DependencyAuditReportPath | ConvertFrom-Json
  $dependencyAuditOk = [bool]$dependencyAudit.pass
}

$nativeSoakExecuted = (-not $UseLegacyPythonAcceptance) -and $IncludeNativeSoak
$nativeSoakOk = $true
$nativeSoak = $null
if ($nativeSoakExecuted) {
  if (-not (Test-Path $NativeSoakScriptPath)) {
    throw "native soak script not found: $NativeSoakScriptPath"
  }

  powershell -NoProfile -ExecutionPolicy Bypass -File $NativeSoakScriptPath `
    -DurationSeconds $SoakDurationSeconds `
    -OutputPath $NativeSoakReportPath | Out-Null

  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: native soak returned non-zero"
  }
  if (-not (Test-Path $NativeSoakReportPath)) {
    throw "release gate failed: missing native soak report $NativeSoakReportPath"
  }
  $nativeSoak = Get-Content -Raw $NativeSoakReportPath | ConvertFrom-Json
  $nativeSoakOk = [bool]$nativeSoak.pass
}

$overallOk = [bool]$acceptance.overall_ok -and $dependencyAuditOk -and $nativeSoakOk
$gate = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  started_at_utc = $startUtc.ToString("o")
  overall_ok = $overallOk
  mode = if ($UseLegacyPythonAcceptance) { "legacy-python" } else { "native" }
  soak_duration_seconds = $SoakDurationSeconds
  acceptance_report_path = (Resolve-Path $acceptancePath).Path
  acceptance = $acceptance
  dependency_audit = [ordered]@{
    executed = $dependencyAuditExecuted
    pass = $dependencyAuditOk
    report_path = if ($dependencyAuditExecuted) { (Resolve-Path $DependencyAuditReportPath).Path } else { "" }
    report = $dependencyAudit
  }
  native_soak = [ordered]@{
    executed = $nativeSoakExecuted
    pass = $nativeSoakOk
    report_path = if ($nativeSoakExecuted) { (Resolve-Path $NativeSoakReportPath).Path } else { "" }
    report = $nativeSoak
  }
}

Ensure-ParentDir $OutputPath
$gate | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("RELEASE_GATE_OK={0}" -f $overallOk)
Write-Output ("RELEASE_GATE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
