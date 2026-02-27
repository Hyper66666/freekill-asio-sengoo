param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "",

  [Parameter(Mandatory = $false)]
  [switch]$Detached,

  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [switch]$SkipPackagePreflight,

  [Parameter(Mandatory = $false)]
  [bool]$RequireFreeKillCore = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

function Assert-PackagePreflight([string]$packagesRootPath, [bool]$requireCore) {
  if (-not (Test-Path $packagesRootPath)) {
    throw "packages root not found: $packagesRootPath"
  }
  $initSqlPath = Join-Path $packagesRootPath "init.sql"
  if (-not (Test-Path $initSqlPath)) {
    throw "packages init.sql not found: $initSqlPath"
  }
  if (-not $requireCore) {
    return
  }
  $coreDir = Join-Path $packagesRootPath "freekill-core"
  $coreEntry = Join-Path $coreDir "lua/server/rpc/entry.lua"
  if (-not (Test-Path $coreDir)) {
    throw "required package directory missing: $coreDir"
  }
  if (-not (Test-Path $coreEntry)) {
    throw "required freekill-core entry missing: $coreEntry"
  }
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$scriptParentDir = Resolve-AbsolutePath -path ".." -baseDir $scriptDir

$candidates = @()
if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
  $candidates += (Resolve-AbsolutePath -path "bin/freekill-asio-sengoo-runtime.exe" -baseDir $scriptParentDir)
  $candidates += (Resolve-AbsolutePath -path "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe" -baseDir $scriptParentDir)
} else {
  $candidates += (Resolve-AbsolutePath -path $BinaryPath -baseDir $scriptParentDir)
}

$resolved = ""
foreach ($candidate in $candidates) {
  if (Test-Path $candidate) {
    $resolved = (Resolve-Path $candidate).Path
    break
  }
}

if ([string]::IsNullOrWhiteSpace($resolved)) {
  throw ("native runtime binary not found. tried: {0}" -f ($candidates -join "; "))
}

$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $scriptParentDir
if (-not $SkipPackagePreflight) {
  Assert-PackagePreflight -packagesRootPath $resolvedPackagesRoot -requireCore $RequireFreeKillCore
}

if ($Detached) {
  $proc = Start-Process -FilePath $resolved -PassThru
  Write-Output ("NATIVE_RUNTIME_STARTED_PID={0}" -f $proc.Id)
  Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
  Write-Output ("NATIVE_RUNTIME_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
  exit 0
}

$proc = Start-Process -FilePath $resolved -PassThru -Wait
$exitCode = [int]$proc.ExitCode
Write-Output ("NATIVE_RUNTIME_EXIT={0}" -f $exitCode)
Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
Write-Output ("NATIVE_RUNTIME_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
exit $exitCode
