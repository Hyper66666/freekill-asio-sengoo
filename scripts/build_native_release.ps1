param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [string]$InputPath = "src/runtime_native_entry.sg",

  [Parameter(Mandatory = $false)]
  [string]$PlatformTag = "windows-x64",

  [Parameter(Mandatory = $false)]
  [string]$ReleaseRoot = "release/native",

  [Parameter(Mandatory = $false)]
  [string]$BinaryName = "",

  [Parameter(Mandatory = $false)]
  [string]$ManifestPath = "",

  [Parameter(Mandatory = $false)]
  [int]$SmokeProbeMilliseconds = 1200
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Dir([string]$path) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

if (-not (Test-Path $SgcPath)) {
  throw "sgc not found: $SgcPath"
}
if (-not (Test-Path $InputPath)) {
  throw "input source not found: $InputPath"
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir

$platformRoot = Join-Path $ReleaseRoot $PlatformTag
$binDir = Join-Path $platformRoot "bin"
$configDir = Join-Path $platformRoot "config"
$scriptsDir = Join-Path $platformRoot "scripts"
$packagesDir = Join-Path $platformRoot "packages"
$tmpBuildDir = ".tmp/native_build"
Ensure-Dir $tmpBuildDir
$inputLeaf = Split-Path -Leaf $InputPath
$tempInputPath = Join-Path $tmpBuildDir $inputLeaf
Copy-Item -Path $InputPath -Destination $tempInputPath -Force

Ensure-Dir $platformRoot
Ensure-Dir $binDir
Ensure-Dir $configDir
Ensure-Dir $scriptsDir
Ensure-Dir $packagesDir

$effectiveBinaryName = if (-not [string]::IsNullOrWhiteSpace($BinaryName)) {
  $BinaryName
} elseif ($PlatformTag -like "windows*") {
  "freekill-asio-sengoo-runtime.exe"
} else {
  "freekill-asio-sengoo-runtime"
}

$outputBinary = Join-Path $binDir $effectiveBinaryName

$customRuntimePath = Resolve-AbsolutePath -path "runtime/runtime.c" -baseDir $repoRoot
$originalSengooRuntime = [string]$env:SENGOO_RUNTIME
$usingCustomRuntime = $false
if (Test-Path $customRuntimePath) {
  $env:SENGOO_RUNTIME = $customRuntimePath
  $usingCustomRuntime = $true
}

try {
  & $SgcPath build $tempInputPath -O 3 --contract-checks off --low-memory --frontend-jobs 1 --force-rebuild -o $outputBinary
} finally {
  if ([string]::IsNullOrWhiteSpace($originalSengooRuntime)) {
    Remove-Item Env:SENGOO_RUNTIME -ErrorAction SilentlyContinue
  } else {
    $env:SENGOO_RUNTIME = $originalSengooRuntime
  }
}
if ($LASTEXITCODE -ne 0) {
  throw "native build failed for $InputPath"
}

if (-not (Test-Path $outputBinary)) {
  throw "missing output binary: $outputBinary"
}

$smoke = Start-Process -FilePath $outputBinary -PassThru
Start-Sleep -Milliseconds $SmokeProbeMilliseconds
$smoke.Refresh()
$smokeExitCode = 0
$smokeMode = "running"
if ($smoke.HasExited) {
  $smokeExitCode = [int]$smoke.ExitCode
  $smokeMode = "exited"
} else {
  Stop-Process -Id $smoke.Id -Force
}

$hash = (Get-FileHash -Algorithm SHA256 -Path $outputBinary).Hash
$manifestOut = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
  Join-Path $platformRoot "manifest.json"
} else {
  $ManifestPath
}

("{0} *{1}" -f $hash.ToLowerInvariant(), (Resolve-Path $outputBinary).Path) | Set-Content -Path (Join-Path $platformRoot "checksums.sha256") -Encoding UTF8

$configTemplatePath = ""
if (Test-Path "scripts/runtime_host.config.example.json") {
  $configTemplatePath = Join-Path $configDir "runtime_host.config.json"
  Copy-Item "scripts/runtime_host.config.example.json" $configTemplatePath -Force
}

$startScriptPath = ""
$healthcheckScriptPath = ""
$installScriptPath = ""
$uninstallScriptPath = ""
$packageManagerScriptPath = ""
$packageCompatScriptPath = ""
$packageSmokeScriptPath = ""
$luaLifecycleScriptPath = ""
$luaLifecycleSmokeScriptPath = ""
$protobufRpcRegressionScriptPath = ""
$protobufRpcFixturesPath = ""
$extensionMatrixScriptPath = ""
$extensionMatrixTargetsPath = ""
$extensionMatrixTargetsExamplePath = ""
$replacementGateScriptPath = ""
$abiHookInventoryScriptPath = ""
$abiHookCompatMapScriptPath = ""
$abiHookValidateScriptPath = ""
$packageInitSqlPath = ""
$packageRegistryPath = ""
if ($PlatformTag -like "windows*") {
  if (Test-Path "scripts/start_runtime_host_native.ps1") {
    $startScriptPath = Join-Path $scriptsDir "start_runtime_host.ps1"
    Copy-Item "scripts/start_runtime_host_native.ps1" $startScriptPath -Force
  }
  if (Test-Path "scripts/healthcheck_runtime_host_native.ps1") {
    $healthcheckScriptPath = Join-Path $scriptsDir "healthcheck_runtime_host.ps1"
    Copy-Item "scripts/healthcheck_runtime_host_native.ps1" $healthcheckScriptPath -Force
  }
  if (Test-Path "scripts/install_runtime_host_windows_task_native.ps1") {
    $installScriptPath = Join-Path $scriptsDir "install_runtime_host_service.ps1"
    Copy-Item "scripts/install_runtime_host_windows_task_native.ps1" $installScriptPath -Force
  }
  if (Test-Path "scripts/uninstall_runtime_host_windows_task_native.ps1") {
    $uninstallScriptPath = Join-Path $scriptsDir "uninstall_runtime_host_service.ps1"
    Copy-Item "scripts/uninstall_runtime_host_windows_task_native.ps1" $uninstallScriptPath -Force
  }
} elseif ($PlatformTag -like "linux*") {
  if (Test-Path "scripts/start_runtime_host_native.sh") {
    $startScriptPath = Join-Path $scriptsDir "start_runtime_host.sh"
    Copy-Item "scripts/start_runtime_host_native.sh" $startScriptPath -Force
  }
  if (Test-Path "scripts/healthcheck_runtime_host_native.sh") {
    $healthcheckScriptPath = Join-Path $scriptsDir "healthcheck_runtime_host.sh"
    Copy-Item "scripts/healthcheck_runtime_host_native.sh" $healthcheckScriptPath -Force
  }
  if (Test-Path "scripts/install_runtime_host_systemd_native.sh") {
    $installScriptPath = Join-Path $scriptsDir "install_runtime_host_service.sh"
    Copy-Item "scripts/install_runtime_host_systemd_native.sh" $installScriptPath -Force
  }
  if (Test-Path "scripts/uninstall_runtime_host_systemd_native.sh") {
    $uninstallScriptPath = Join-Path $scriptsDir "uninstall_runtime_host_service.sh"
    Copy-Item "scripts/uninstall_runtime_host_systemd_native.sh" $uninstallScriptPath -Force
  }
}

if (Test-Path "scripts/package_manager_native.ps1") {
  $packageManagerScriptPath = Join-Path $scriptsDir "package_manager.ps1"
  Copy-Item "scripts/package_manager_native.ps1" $packageManagerScriptPath -Force
}
if (Test-Path "scripts/check_package_compatibility_native.ps1") {
  $packageCompatScriptPath = Join-Path $scriptsDir "check_package_compatibility.ps1"
  Copy-Item "scripts/check_package_compatibility_native.ps1" $packageCompatScriptPath -Force
}
if (Test-Path "scripts/package_manager_smoke_native.ps1") {
  $packageSmokeScriptPath = Join-Path $scriptsDir "package_manager_smoke.ps1"
  Copy-Item "scripts/package_manager_smoke_native.ps1" $packageSmokeScriptPath -Force
}
if (Test-Path "scripts/lua_extension_lifecycle_native.ps1") {
  $luaLifecycleScriptPath = Join-Path $scriptsDir "lua_extension_lifecycle.ps1"
  Copy-Item "scripts/lua_extension_lifecycle_native.ps1" $luaLifecycleScriptPath -Force
}
if (Test-Path "scripts/lua_extension_lifecycle_smoke_native.ps1") {
  $luaLifecycleSmokeScriptPath = Join-Path $scriptsDir "lua_extension_lifecycle_smoke.ps1"
  Copy-Item "scripts/lua_extension_lifecycle_smoke_native.ps1" $luaLifecycleSmokeScriptPath -Force
}
if (Test-Path "scripts/run_protobuf_rpc_regression_native.ps1") {
  $protobufRpcRegressionScriptPath = Join-Path $scriptsDir "run_protobuf_rpc_regression.ps1"
  Copy-Item "scripts/run_protobuf_rpc_regression_native.ps1" $protobufRpcRegressionScriptPath -Force
}
if (Test-Path "scripts/run_extension_matrix_native.ps1") {
  $extensionMatrixScriptPath = Join-Path $scriptsDir "run_extension_matrix.ps1"
  Copy-Item "scripts/run_extension_matrix_native.ps1" $extensionMatrixScriptPath -Force
}
if (Test-Path "scripts/runtime_host_replacement_gate_native.ps1") {
  $replacementGateScriptPath = Join-Path $scriptsDir "runtime_host_replacement_gate.ps1"
  Copy-Item "scripts/runtime_host_replacement_gate_native.ps1" $replacementGateScriptPath -Force
}
if (Test-Path "scripts/fixtures/protobuf_rpc_regression_cases.json") {
  $fixturesDir = Join-Path $scriptsDir "fixtures"
  Ensure-Dir $fixturesDir
  $protobufRpcFixturesPath = Join-Path $fixturesDir "protobuf_rpc_regression_cases.json"
  Copy-Item "scripts/fixtures/protobuf_rpc_regression_cases.json" $protobufRpcFixturesPath -Force
}
if (Test-Path "scripts/fixtures/extension_matrix_targets.json") {
  $fixturesDir = Join-Path $scriptsDir "fixtures"
  Ensure-Dir $fixturesDir
  $extensionMatrixTargetsPath = Join-Path $fixturesDir "extension_matrix_targets.json"
  Copy-Item "scripts/fixtures/extension_matrix_targets.json" $extensionMatrixTargetsPath -Force
}
if (Test-Path "scripts/fixtures/extension_matrix_targets.example.json") {
  $fixturesDir = Join-Path $scriptsDir "fixtures"
  Ensure-Dir $fixturesDir
  $extensionMatrixTargetsExamplePath = Join-Path $fixturesDir "extension_matrix_targets.example.json"
  Copy-Item "scripts/fixtures/extension_matrix_targets.example.json" $extensionMatrixTargetsExamplePath -Force
}
if (Test-Path "scripts/build_extension_abi_hook_inventory.ps1") {
  $abiHookInventoryScriptPath = Join-Path $scriptsDir "build_extension_abi_hook_inventory.ps1"
  Copy-Item "scripts/build_extension_abi_hook_inventory.ps1" $abiHookInventoryScriptPath -Force
}
if (Test-Path "scripts/build_extension_abi_hook_compat_map.ps1") {
  $abiHookCompatMapScriptPath = Join-Path $scriptsDir "build_extension_abi_hook_compat_map.ps1"
  Copy-Item "scripts/build_extension_abi_hook_compat_map.ps1" $abiHookCompatMapScriptPath -Force
}
if (Test-Path "scripts/validate_extension_abi_hook_compatibility.ps1") {
  $abiHookValidateScriptPath = Join-Path $scriptsDir "validate_extension_abi_hook_compatibility.ps1"
  Copy-Item "scripts/validate_extension_abi_hook_compatibility.ps1" $abiHookValidateScriptPath -Force
}
if (Test-Path "packages/init.sql") {
  $packageInitSqlPath = Join-Path $packagesDir "init.sql"
  Copy-Item "packages/init.sql" $packageInitSqlPath -Force
} else {
  $packageInitSqlPath = Join-Path $packagesDir "init.sql"
  @"
CREATE TABLE IF NOT EXISTS packages (
  name VARCHAR(128),
  url VARCHAR(255),
  hash CHAR(40),
  enabled BOOLEAN
);
"@ | Set-Content -Path $packageInitSqlPath -Encoding UTF8
}
$packageRegistryPath = Join-Path $packagesDir "packages.registry.json"
if (-not (Test-Path $packageRegistryPath)) {
  "[]" | Set-Content -Path $packageRegistryPath -Encoding UTF8
}

$manifest = [ordered]@{
  version = "0.2.0-native"
  runtime_mode = "native"
  python_required = $false
  platform = $PlatformTag
  build_time_utc = (Get-Date).ToUniversalTime().ToString("o")
  source = $InputPath
  custom_runtime_path = if ($usingCustomRuntime) { $customRuntimePath } else { "" }
  binary_path = (Resolve-Path $outputBinary).Path
  binary_sha256 = $hash
  smoke_exit_code = $smokeExitCode
  smoke_mode = $smokeMode
  smoke_probe_ms = $SmokeProbeMilliseconds
  config_template_path = if ([string]::IsNullOrWhiteSpace($configTemplatePath)) {
    ""
  } else {
    (Resolve-Path $configTemplatePath).Path
  }
  start_script_path = if ([string]::IsNullOrWhiteSpace($startScriptPath)) {
    ""
  } else {
    (Resolve-Path $startScriptPath).Path
  }
  healthcheck_script_path = if ([string]::IsNullOrWhiteSpace($healthcheckScriptPath)) {
    ""
  } else {
    (Resolve-Path $healthcheckScriptPath).Path
  }
  install_script_path = if ([string]::IsNullOrWhiteSpace($installScriptPath)) {
    ""
  } else {
    (Resolve-Path $installScriptPath).Path
  }
  uninstall_script_path = if ([string]::IsNullOrWhiteSpace($uninstallScriptPath)) {
    ""
  } else {
    (Resolve-Path $uninstallScriptPath).Path
  }
  package_manager_script_path = if ([string]::IsNullOrWhiteSpace($packageManagerScriptPath)) {
    ""
  } else {
    (Resolve-Path $packageManagerScriptPath).Path
  }
  package_compatibility_script_path = if ([string]::IsNullOrWhiteSpace($packageCompatScriptPath)) {
    ""
  } else {
    (Resolve-Path $packageCompatScriptPath).Path
  }
  package_smoke_script_path = if ([string]::IsNullOrWhiteSpace($packageSmokeScriptPath)) {
    ""
  } else {
    (Resolve-Path $packageSmokeScriptPath).Path
  }
  lua_lifecycle_script_path = if ([string]::IsNullOrWhiteSpace($luaLifecycleScriptPath)) {
    ""
  } else {
    (Resolve-Path $luaLifecycleScriptPath).Path
  }
  lua_lifecycle_smoke_script_path = if ([string]::IsNullOrWhiteSpace($luaLifecycleSmokeScriptPath)) {
    ""
  } else {
    (Resolve-Path $luaLifecycleSmokeScriptPath).Path
  }
  protobuf_rpc_regression_script_path = if ([string]::IsNullOrWhiteSpace($protobufRpcRegressionScriptPath)) {
    ""
  } else {
    (Resolve-Path $protobufRpcRegressionScriptPath).Path
  }
  protobuf_rpc_fixtures_path = if ([string]::IsNullOrWhiteSpace($protobufRpcFixturesPath)) {
    ""
  } else {
    (Resolve-Path $protobufRpcFixturesPath).Path
  }
  extension_matrix_script_path = if ([string]::IsNullOrWhiteSpace($extensionMatrixScriptPath)) {
    ""
  } else {
    (Resolve-Path $extensionMatrixScriptPath).Path
  }
  extension_matrix_targets_path = if ([string]::IsNullOrWhiteSpace($extensionMatrixTargetsPath)) {
    ""
  } else {
    (Resolve-Path $extensionMatrixTargetsPath).Path
  }
  extension_matrix_targets_example_path = if ([string]::IsNullOrWhiteSpace($extensionMatrixTargetsExamplePath)) {
    ""
  } else {
    (Resolve-Path $extensionMatrixTargetsExamplePath).Path
  }
  replacement_gate_script_path = if ([string]::IsNullOrWhiteSpace($replacementGateScriptPath)) {
    ""
  } else {
    (Resolve-Path $replacementGateScriptPath).Path
  }
  abi_hook_inventory_script_path = if ([string]::IsNullOrWhiteSpace($abiHookInventoryScriptPath)) {
    ""
  } else {
    (Resolve-Path $abiHookInventoryScriptPath).Path
  }
  abi_hook_compat_map_script_path = if ([string]::IsNullOrWhiteSpace($abiHookCompatMapScriptPath)) {
    ""
  } else {
    (Resolve-Path $abiHookCompatMapScriptPath).Path
  }
  abi_hook_validate_script_path = if ([string]::IsNullOrWhiteSpace($abiHookValidateScriptPath)) {
    ""
  } else {
    (Resolve-Path $abiHookValidateScriptPath).Path
  }
  package_init_sql_path = (Resolve-Path $packageInitSqlPath).Path
  package_registry_path = (Resolve-Path $packageRegistryPath).Path
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestOut -Encoding UTF8

Write-Output "PASS native release build"
Write-Output ("BINARY={0}" -f (Resolve-Path $outputBinary).Path)
Write-Output ("MANIFEST={0}" -f (Resolve-Path $manifestOut).Path)
Write-Output ("SMOKE_EXIT={0}" -f $smokeExitCode)
