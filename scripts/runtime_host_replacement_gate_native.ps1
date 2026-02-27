param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [int]$SoakDurationSeconds = 60,

  [Parameter(Mandatory = $false)]
  [switch]$EnforceAbiHookCompatibility = $true,

  [Parameter(Mandatory = $false)]
  [string]$ExtensionMatrixTargetsPath = "scripts/fixtures/extension_matrix_targets.json",

  [Parameter(Mandatory = $false)]
  [switch]$UseLocalExtensionMatrixFixture,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_replacement_gate_native.json"
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

$verifyScript = "scripts/verify_native_release.ps1"
$gateScript = "scripts/runtime_host_release_gate.ps1"
if (-not (Test-Path $verifyScript)) {
  throw "verify script not found: $verifyScript"
}
if (-not (Test-Path $gateScript)) {
  throw "release gate script not found: $gateScript"
}

$verifyExitCode = 0
$verifyError = ""
try {
  powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript `
    -SgcPath $SgcPath `
    -SoakDurationSeconds $SoakDurationSeconds | Out-Null
  $verifyExitCode = [int]$LASTEXITCODE
  if ($verifyExitCode -ne 0) {
    $verifyError = "verify_native_release returned non-zero"
  }
} catch {
  $verifyExitCode = 1
  $verifyError = $_.Exception.Message
}

$gateArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $gateScript,
  "-SgcPath",
  $SgcPath,
  "-SoakDurationSeconds",
  $SoakDurationSeconds,
  "-ExtensionMatrixTargetsPath",
  $ExtensionMatrixTargetsPath
)
if ([bool]$EnforceAbiHookCompatibility) {
  $gateArgs += "-EnforceAbiHookCompatibility"
}
if ([bool]$UseLocalExtensionMatrixFixture) {
  $gateArgs += "-UseLocalExtensionMatrixFixture"
}
$gateReportPath = ".tmp/runtime_host/runtime_host_release_gate.json"
if (Test-Path $gateReportPath) {
  Remove-Item -Force $gateReportPath
}
$gateExitCode = 0
$gateError = ""
try {
  powershell @gateArgs | Out-Null
  $gateExitCode = [int]$LASTEXITCODE
  if ($gateExitCode -ne 0) {
    $gateError = "runtime_host_release_gate returned non-zero"
  }
} catch {
  $gateExitCode = 1
  $gateError = $_.Exception.Message
}
$gate = $null
if ($gateExitCode -eq 0 -and (Test-Path $gateReportPath)) {
  $gate = Get-Content -Raw $gateReportPath | ConvertFrom-Json
}

$checks = [ordered]@{
  acceptance = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.acceptance.overall_ok } else { $false }
  package_compatibility = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.package_compatibility.pass } else { $false }
  abi_hook = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.abi_hook_compatibility.gate_pass } else { $false }
  lua_lifecycle = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.lua_lifecycle.pass } else { $false }
  protobuf_rpc = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.protobuf_rpc_regression.pass } else { $false }
  extension_matrix = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.extension_matrix.pass } else { $false }
  dependency_audit = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.dependency_audit.pass } else { $false }
  native_soak = if ($gateExitCode -eq 0 -and $null -ne $gate) { [bool]$gate.native_soak.pass } else { $false }
}

$replaceable = ($gateExitCode -eq 0) `
  -and [bool]$checks.acceptance `
  -and [bool]$checks.package_compatibility `
  -and [bool]$checks.abi_hook `
  -and [bool]$checks.lua_lifecycle `
  -and [bool]$checks.protobuf_rpc `
  -and [bool]$checks.extension_matrix `
  -and [bool]$checks.dependency_audit `
  -and [bool]$checks.native_soak

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  replaceable = $replaceable
  enforce_abi_hook_compatibility = [bool]$EnforceAbiHookCompatibility
  soak_duration_seconds = $SoakDurationSeconds
  verify_exit_code = $verifyExitCode
  verify_error = $verifyError
  gate_exit_code = $gateExitCode
  gate_error = $gateError
  checks = $checks
  release_gate_report_path = if (Test-Path $gateReportPath) { (Resolve-Path $gateReportPath).Path } else { $gateReportPath }
  release_gate = $gate
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 16 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("RUNTIME_REPLACEMENT_GATE_OK={0}" -f $replaceable)
Write-Output ("RUNTIME_REPLACEMENT_GATE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $replaceable) {
  exit 1
}
