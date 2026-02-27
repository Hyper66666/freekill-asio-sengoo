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
  [bool]$IncludePackageCompatibility = $true,

  [Parameter(Mandatory = $false)]
  [string]$PackageCompatibilityScriptPath = "scripts/check_package_compatibility_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$PackageCompatibilityReportPath = ".tmp/runtime_host/package_compatibility_report.json",

  [Parameter(Mandatory = $false)]
  [switch]$SkipAbiHookCompatibility,

  [Parameter(Mandatory = $false)]
  [string]$AbiHookValidationScriptPath = "scripts/validate_extension_abi_hook_compatibility.ps1",

  [Parameter(Mandatory = $false)]
  [string]$AbiHookValidationReportPath = ".tmp/runtime_host/abi_hook_validation_report.json",

  [Parameter(Mandatory = $false)]
  [switch]$EnforceAbiHookCompatibility,

  [Parameter(Mandatory = $false)]
  [switch]$AllowPartialAbiHookCompatibility,

  [Parameter(Mandatory = $false)]
  [bool]$IncludeLuaLifecycleSmoke = $true,

  [Parameter(Mandatory = $false)]
  [string]$LuaLifecycleSmokeScriptPath = "scripts/lua_extension_lifecycle_smoke_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$LuaLifecycleSmokeReportPath = ".tmp/runtime_host/lua_extension_lifecycle_smoke_native.json",

  [Parameter(Mandatory = $false)]
  [bool]$IncludeProtobufRpcRegression = $true,

  [Parameter(Mandatory = $false)]
  [string]$ProtobufRpcRegressionScriptPath = "scripts/run_protobuf_rpc_regression_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$ProtobufRpcRegressionReportPath = ".tmp/runtime_host/protobuf_rpc_regression_native_report.json",

  [Parameter(Mandatory = $false)]
  [bool]$IncludeExtensionMatrix = $true,

  [Parameter(Mandatory = $false)]
  [string]$ExtensionMatrixScriptPath = "scripts/run_extension_matrix_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$ExtensionMatrixReportPath = ".tmp/runtime_host/extension_matrix_native_report.json",

  [Parameter(Mandatory = $false)]
  [string]$ExtensionMatrixTargetsPath = "scripts/fixtures/extension_matrix_targets.json",

  [Parameter(Mandatory = $false)]
  [switch]$UseLocalExtensionMatrixFixture,

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

  & $NativeAcceptanceScriptPath `
    -SgcPath $SgcPath `
    -IncludePackageCompatibility $IncludePackageCompatibility `
    -PackageCompatibilityScriptPath $PackageCompatibilityScriptPath `
    -PackageCompatibilityReportPath $PackageCompatibilityReportPath | Out-Null

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
$packageCompatExecuted = (-not $UseLegacyPythonAcceptance) -and $IncludePackageCompatibility
$packageCompatOk = $true
$packageCompat = $null
if ($packageCompatExecuted) {
  if ($null -eq $acceptance.package_compatibility) {
    throw "release gate failed: native acceptance missing package_compatibility section"
  }
  $packageCompat = $acceptance.package_compatibility
  $packageCompatOk = [bool]$packageCompat.ok
}

$abiHookExecuted = (-not $UseLegacyPythonAcceptance) -and (-not $SkipAbiHookCompatibility)
$abiHookPass = $true
$abiHookReportPass = $true
$abiHook = $null
if ($abiHookExecuted) {
  if (-not (Test-Path $AbiHookValidationScriptPath)) {
    throw "abi/hook validation script not found: $AbiHookValidationScriptPath"
  }
  $abiHookArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $AbiHookValidationScriptPath,
    "-OutputPath",
    $AbiHookValidationReportPath
  )
  if ([bool]$AllowPartialAbiHookCompatibility) {
    $abiHookArgs += "-AllowPartial"
  }
  if ([bool]$EnforceAbiHookCompatibility) {
    $abiHookArgs += "-Enforce"
  }
  & powershell @abiHookArgs | Out-Null
  if ($LASTEXITCODE -ne 0 -and [bool]$EnforceAbiHookCompatibility) {
    throw "release gate failed: abi/hook validation returned non-zero under enforce mode"
  }
  if (-not (Test-Path $AbiHookValidationReportPath)) {
    throw "release gate failed: missing abi/hook validation report $AbiHookValidationReportPath"
  }
  $abiHook = Get-Content -Raw $AbiHookValidationReportPath | ConvertFrom-Json
  $abiHookReportPass = [bool]$abiHook.pass
  if ([bool]$EnforceAbiHookCompatibility) {
    $abiHookPass = $abiHookReportPass
  }
}

$luaLifecycleExecuted = (-not $UseLegacyPythonAcceptance) -and $IncludeLuaLifecycleSmoke
$luaLifecycleOk = $true
$luaLifecycle = $null
if ($luaLifecycleExecuted) {
  if (-not (Test-Path $LuaLifecycleSmokeScriptPath)) {
    throw "lua lifecycle smoke script not found: $LuaLifecycleSmokeScriptPath"
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File $LuaLifecycleSmokeScriptPath `
    -OutputPath $LuaLifecycleSmokeReportPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: lua lifecycle smoke returned non-zero"
  }
  if (-not (Test-Path $LuaLifecycleSmokeReportPath)) {
    throw "release gate failed: missing lua lifecycle smoke report $LuaLifecycleSmokeReportPath"
  }
  $luaLifecycle = Get-Content -Raw $LuaLifecycleSmokeReportPath | ConvertFrom-Json
  $luaLifecycleOk = [bool]$luaLifecycle.pass
}

$protobufRpcExecuted = (-not $UseLegacyPythonAcceptance) -and $IncludeProtobufRpcRegression
$protobufRpcOk = $true
$protobufRpc = $null
if ($protobufRpcExecuted) {
  if (-not (Test-Path $ProtobufRpcRegressionScriptPath)) {
    throw "protobuf/rpc regression script not found: $ProtobufRpcRegressionScriptPath"
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File $ProtobufRpcRegressionScriptPath `
    -StartRuntime `
    -OutputPath $ProtobufRpcRegressionReportPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: protobuf/rpc regression returned non-zero"
  }
  if (-not (Test-Path $ProtobufRpcRegressionReportPath)) {
    throw "release gate failed: missing protobuf/rpc regression report $ProtobufRpcRegressionReportPath"
  }
  $protobufRpc = Get-Content -Raw $ProtobufRpcRegressionReportPath | ConvertFrom-Json
  $protobufRpcOk = [bool]$protobufRpc.pass
}

$extensionMatrixExecuted = (-not $UseLegacyPythonAcceptance) -and $IncludeExtensionMatrix
$extensionMatrixOk = $true
$extensionMatrix = $null
if ($extensionMatrixExecuted) {
  if (-not (Test-Path $ExtensionMatrixScriptPath)) {
    throw "extension matrix script not found: $ExtensionMatrixScriptPath"
  }
  $matrixArgs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $ExtensionMatrixScriptPath,
    "-TargetsPath", $ExtensionMatrixTargetsPath,
    "-OutputPath", $ExtensionMatrixReportPath
  )
  if ([bool]$UseLocalExtensionMatrixFixture) {
    $matrixArgs += "-UseLocalFixture"
  }
  & powershell @matrixArgs | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "release gate failed: extension matrix returned non-zero"
  }
  if (-not (Test-Path $ExtensionMatrixReportPath)) {
    throw "release gate failed: missing extension matrix report $ExtensionMatrixReportPath"
  }
  $extensionMatrix = Get-Content -Raw $ExtensionMatrixReportPath | ConvertFrom-Json
  $extensionMatrixOk = [bool]$extensionMatrix.pass
}

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

$overallOk = [bool]$acceptance.overall_ok -and $dependencyAuditOk -and $nativeSoakOk -and $packageCompatOk -and $abiHookPass -and $luaLifecycleOk -and $protobufRpcOk -and $extensionMatrixOk
$gate = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  started_at_utc = $startUtc.ToString("o")
  overall_ok = $overallOk
  mode = if ($UseLegacyPythonAcceptance) { "legacy-python" } else { "native" }
  soak_duration_seconds = $SoakDurationSeconds
  acceptance_report_path = (Resolve-Path $acceptancePath).Path
  acceptance = $acceptance
  package_compatibility = [ordered]@{
    executed = $packageCompatExecuted
    pass = $packageCompatOk
    report_path = if ($packageCompatExecuted -and -not [string]::IsNullOrWhiteSpace([string]$packageCompat.report_path)) {
      [string]$packageCompat.report_path
    } elseif ($packageCompatExecuted -and (Test-Path $PackageCompatibilityReportPath)) {
      (Resolve-Path $PackageCompatibilityReportPath).Path
    } else {
      ""
    }
    report = if ($packageCompatExecuted) { $packageCompat.report } else { $null }
  }
  abi_hook_compatibility = [ordered]@{
    executed = $abiHookExecuted
    enforced = [bool]$EnforceAbiHookCompatibility
    allow_partial = [bool]$AllowPartialAbiHookCompatibility
    pass = $abiHookReportPass
    gate_pass = $abiHookPass
    report_path = if ($abiHookExecuted) { (Resolve-Path $AbiHookValidationReportPath).Path } else { "" }
    report = $abiHook
  }
  lua_lifecycle = [ordered]@{
    executed = $luaLifecycleExecuted
    pass = $luaLifecycleOk
    report_path = if ($luaLifecycleExecuted) { (Resolve-Path $LuaLifecycleSmokeReportPath).Path } else { "" }
    report = $luaLifecycle
  }
  protobuf_rpc_regression = [ordered]@{
    executed = $protobufRpcExecuted
    pass = $protobufRpcOk
    report_path = if ($protobufRpcExecuted) { (Resolve-Path $ProtobufRpcRegressionReportPath).Path } else { "" }
    report = $protobufRpc
  }
  extension_matrix = [ordered]@{
    executed = $extensionMatrixExecuted
    pass = $extensionMatrixOk
    report_path = if ($extensionMatrixExecuted) { (Resolve-Path $ExtensionMatrixReportPath).Path } else { "" }
    report = $extensionMatrix
  }
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
