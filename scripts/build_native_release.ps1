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
  [string]$BinaryName = "freekill-asio-sengoo-runtime.exe",

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

$outputBinary = Join-Path $binDir $BinaryName

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

$manifest = [ordered]@{
  version = "0.1.0-native-bootstrap"
  platform = $PlatformTag
  build_time_utc = (Get-Date).ToUniversalTime().ToString("o")
  source = $InputPath
  binary_path = (Resolve-Path $outputBinary).Path
  binary_sha256 = $hash
  smoke_exit_code = $smokeExitCode
}

$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestOut -Encoding UTF8
("{0} *{1}" -f $hash.ToLowerInvariant(), (Resolve-Path $outputBinary).Path) | Set-Content -Path (Join-Path $platformRoot "checksums.sha256") -Encoding UTF8

if (Test-Path "scripts/runtime_host.config.example.json") {
  Copy-Item "scripts/runtime_host.config.example.json" (Join-Path $configDir "runtime_host.config.json") -Force
}
if (Test-Path "scripts/start_runtime_host_watchdog.ps1") {
  Copy-Item "scripts/start_runtime_host_watchdog.ps1" (Join-Path $scriptsDir "start_runtime_host.ps1") -Force
}
if (Test-Path "scripts/runtime_host_healthcheck.ps1") {
  Copy-Item "scripts/runtime_host_healthcheck.ps1" (Join-Path $scriptsDir "healthcheck_runtime_host.ps1") -Force
}

Write-Output "PASS native release build"
Write-Output ("BINARY={0}" -f (Resolve-Path $outputBinary).Path)
Write-Output ("MANIFEST={0}" -f (Resolve-Path $manifestOut).Path)
Write-Output ("SMOKE_EXIT={0}" -f $smokeExitCode)
