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
  [string]$ManifestPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Dir([string]$path) {
  if (-not (Test-Path $path)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }
}

if (-not (Test-Path $SgcPath)) {
  throw "sgc not found: $SgcPath"
}
if (-not (Test-Path $InputPath)) {
  throw "input source not found: $InputPath"
}

$platformRoot = Join-Path $ReleaseRoot $PlatformTag
$binDir = Join-Path $platformRoot "bin"
$configDir = Join-Path $platformRoot "config"
$scriptsDir = Join-Path $platformRoot "scripts"
$tmpBuildDir = ".tmp/native_build"
Ensure-Dir $tmpBuildDir
$inputLeaf = Split-Path -Leaf $InputPath
$tempInputPath = Join-Path $tmpBuildDir $inputLeaf
Copy-Item -Path $InputPath -Destination $tempInputPath -Force

Ensure-Dir $platformRoot
Ensure-Dir $binDir
Ensure-Dir $configDir
Ensure-Dir $scriptsDir

$effectiveBinaryName = if (-not [string]::IsNullOrWhiteSpace($BinaryName)) {
  $BinaryName
} elseif ($PlatformTag -like "windows*") {
  "freekill-asio-sengoo-runtime.exe"
} else {
  "freekill-asio-sengoo-runtime"
}

$outputBinary = Join-Path $binDir $effectiveBinaryName

& $SgcPath build $tempInputPath -O 3 --contract-checks off --low-memory --frontend-jobs 1 --force-rebuild -o $outputBinary
if ($LASTEXITCODE -ne 0) {
  throw "native build failed for $InputPath"
}

if (-not (Test-Path $outputBinary)) {
  throw "missing output binary: $outputBinary"
}

$smoke = Start-Process -FilePath $outputBinary -PassThru -Wait
$smokeExitCode = [int]$smoke.ExitCode

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

$manifest = [ordered]@{
  version = "0.2.0-native"
  runtime_mode = "native"
  python_required = $false
  platform = $PlatformTag
  build_time_utc = (Get-Date).ToUniversalTime().ToString("o")
  source = $InputPath
  binary_path = (Resolve-Path $outputBinary).Path
  binary_sha256 = $hash
  smoke_exit_code = $smokeExitCode
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
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestOut -Encoding UTF8

Write-Output "PASS native release build"
Write-Output ("BINARY={0}" -f (Resolve-Path $outputBinary).Path)
Write-Output ("MANIFEST={0}" -f (Resolve-Path $manifestOut).Path)
Write-Output ("SMOKE_EXIT={0}" -f $smokeExitCode)
