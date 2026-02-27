param(
  [Parameter(Mandatory = $false)]
  [string]$SgcPath = "C:\Users\tomi\Desktop\Gemini\Sengoo\target\release\sgc.exe",

  [Parameter(Mandatory = $false)]
  [string]$NativeEntryPath = "src/runtime_native_entry.sg",

  [Parameter(Mandatory = $false)]
  [string]$BuildScriptPath = "scripts/build_native_release.ps1",

  [Parameter(Mandatory = $false)]
  [string]$PlatformTag = "windows-x64",

  [Parameter(Mandatory = $false)]
  [string]$ReleaseRoot = "release/native",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_acceptance_native.json",

  [Parameter(Mandatory = $false)]
  [int]$ProbeTcpPort = 9527,

  [Parameter(Mandatory = $false)]
  [int]$ProbeWarmupMilliseconds = 1500,

  [Parameter(Mandatory = $false)]
  [int]$ProbeConnectTimeoutMs = 600,

  [Parameter(Mandatory = $false)]
  [bool]$IncludePackageCompatibility = $true,

  [Parameter(Mandatory = $false)]
  [string]$PackageCompatibilityScriptPath = "scripts/check_package_compatibility_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$PackageCompatibilityReportPath = ".tmp/runtime_host/package_compatibility_report.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Test-TcpPort([string]$targetHost, [int]$port, [int]$timeoutMs) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($targetHost, $port)
    if (-not $task.Wait($timeoutMs)) {
      return $false
    }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}

if (-not (Test-Path $SgcPath)) {
  throw "sgc not found: $SgcPath"
}
if (-not (Test-Path $NativeEntryPath)) {
  throw "native entry not found: $NativeEntryPath"
}
if (-not (Test-Path $BuildScriptPath)) {
  throw "build script not found: $BuildScriptPath"
}

& $SgcPath check $NativeEntryPath | Out-Null
$sgcCheckExitCode = [int]$LASTEXITCODE
if ($sgcCheckExitCode -ne 0) {
  throw "sgc check failed for $NativeEntryPath (exit=$sgcCheckExitCode)"
}

powershell -NoProfile -ExecutionPolicy Bypass -File $BuildScriptPath `
  -SgcPath $SgcPath `
  -InputPath $NativeEntryPath `
  -PlatformTag $PlatformTag `
  -ReleaseRoot $ReleaseRoot | Out-Null

if ($LASTEXITCODE -ne 0) {
  throw "native release build failed"
}

$packageCompatExecuted = [bool]$IncludePackageCompatibility
$packageCompatOk = $true
$packageCompat = $null
if ($packageCompatExecuted) {
  if (-not (Test-Path $PackageCompatibilityScriptPath)) {
    throw "package compatibility script not found: $PackageCompatibilityScriptPath"
  }
  powershell -NoProfile -ExecutionPolicy Bypass -File $PackageCompatibilityScriptPath `
    -OutputPath $PackageCompatibilityReportPath | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "package compatibility check failed"
  }
  if (-not (Test-Path $PackageCompatibilityReportPath)) {
    throw "missing package compatibility report: $PackageCompatibilityReportPath"
  }
  $packageCompat = Get-Content -Raw $PackageCompatibilityReportPath | ConvertFrom-Json
  $packageCompatOk = [bool]$packageCompat.pass
}

$platformRoot = Join-Path $ReleaseRoot $PlatformTag
$manifestPath = Join-Path $platformRoot "manifest.json"
$checksumPath = Join-Path $platformRoot "checksums.sha256"

if (-not (Test-Path $manifestPath)) {
  throw "missing native build manifest: $manifestPath"
}
if (-not (Test-Path $checksumPath)) {
  throw "missing native checksum file: $checksumPath"
}

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
$binaryPath = [string]$manifest.binary_path
if ([string]::IsNullOrWhiteSpace($binaryPath)) {
  throw "manifest missing binary_path"
}
if (-not (Test-Path $binaryPath)) {
  throw "manifest binary missing: $binaryPath"
}

$smokeExitCode = [int]$manifest.smoke_exit_code
$probe = Start-Process -FilePath $binaryPath -PassThru
Start-Sleep -Milliseconds $ProbeWarmupMilliseconds
$probe.Refresh()
$probeRunning = -not $probe.HasExited
$probeExitCode = if ($probe.HasExited) { [int]$probe.ExitCode } else { 0 }
$probePortOpen = $false
if ($probeRunning) {
  $probePortOpen = Test-TcpPort -targetHost "127.0.0.1" -port $ProbeTcpPort -timeoutMs $ProbeConnectTimeoutMs
  Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
}

$manifestHash = [string]$manifest.binary_sha256
$actualHash = (Get-FileHash -Algorithm SHA256 -Path $binaryPath).Hash.ToLowerInvariant()
$hashMatch = ($manifestHash.ToLowerInvariant() -eq $actualHash)

$overallOk = ($smokeExitCode -eq 0) -and $probeRunning -and $probePortOpen -and $hashMatch -and $packageCompatOk

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  overall_ok = $overallOk
  mode = "native"
  sgc_check = [ordered]@{
    target = $NativeEntryPath
    exit_code = $sgcCheckExitCode
    ok = ($sgcCheckExitCode -eq 0)
  }
  artifact = [ordered]@{
    platform = $PlatformTag
    manifest_path = (Resolve-Path $manifestPath).Path
    checksum_path = (Resolve-Path $checksumPath).Path
    binary_path = (Resolve-Path $binaryPath).Path
    smoke_exit_code = $smokeExitCode
    probe_running = $probeRunning
    probe_exit_code = $probeExitCode
    probe_tcp_port = $ProbeTcpPort
    probe_port_open = $probePortOpen
    hash_match = $hashMatch
  }
  package_compatibility = [ordered]@{
    executed = $packageCompatExecuted
    ok = $packageCompatOk
    report_path = if ($packageCompatExecuted) { (Resolve-Path $PackageCompatibilityReportPath).Path } else { "" }
    report = $packageCompat
  }
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("ACCEPTANCE_NATIVE_OK={0}" -f $overallOk)
Write-Output ("ACCEPTANCE_NATIVE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $overallOk) {
  exit 1
}
