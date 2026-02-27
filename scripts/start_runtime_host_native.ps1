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
  [bool]$RequireFreeKillCore = $true,

  [Parameter(Mandatory = $false)]
  [string]$LogDir = ".tmp/runtime_host",

  [Parameter(Mandatory = $false)]
  [string]$StdoutLogPath = "",

  [Parameter(Mandatory = $false)]
  [string]$StderrLogPath = "",

  [Parameter(Mandatory = $false)]
  [string]$EventLogPath = "",

  [Parameter(Mandatory = $false)]
  [switch]$NoRedirectLogs,

  [Parameter(Mandatory = $false)]
  [int]$DetachedProbeMilliseconds = 1200
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Write-EventLogLine([string]$eventLogPath, [string]$level, [string]$message) {
  $line = ("{0}`t{1}`t{2}" -f (Get-Date).ToUniversalTime().ToString("o"), $level, $message)
  Add-Content -Path $eventLogPath -Encoding UTF8 -Value $line
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

$effectiveNoRedirectLogs = [bool]$NoRedirectLogs
if (-not [bool]$Detached -and -not [bool]$NoRedirectLogs) {
  $effectiveNoRedirectLogs = $true
}

$resolvedLogDir = Resolve-AbsolutePath -path $LogDir -baseDir $scriptParentDir
if (-not (Test-Path $resolvedLogDir)) {
  New-Item -ItemType Directory -Path $resolvedLogDir -Force | Out-Null
}
$resolvedStdoutLogPath = if ([string]::IsNullOrWhiteSpace($StdoutLogPath)) {
  Join-Path $resolvedLogDir "native_runtime.stdout.log"
} else {
  Resolve-AbsolutePath -path $StdoutLogPath -baseDir $scriptParentDir
}
$resolvedStderrLogPath = if ([string]::IsNullOrWhiteSpace($StderrLogPath)) {
  Join-Path $resolvedLogDir "native_runtime.stderr.log"
} else {
  Resolve-AbsolutePath -path $StderrLogPath -baseDir $scriptParentDir
}
$resolvedEventLogPath = if ([string]::IsNullOrWhiteSpace($EventLogPath)) {
  Join-Path $resolvedLogDir "native_runtime.events.log"
} else {
  Resolve-AbsolutePath -path $EventLogPath -baseDir $scriptParentDir
}
Ensure-ParentDir $resolvedStdoutLogPath
Ensure-ParentDir $resolvedStderrLogPath
Ensure-ParentDir $resolvedEventLogPath

$logMode = if ([bool]$effectiveNoRedirectLogs) { "none" } else { "file" }
Write-EventLogLine `
  -eventLogPath $resolvedEventLogPath `
  -level "INFO" `
  -message ("launch_requested detached={0}; binary={1}; packages_root={2}; log_mode={3}" -f [bool]$Detached, $resolved, $resolvedPackagesRoot, $logMode)

if ($Detached) {
  $startArgs = @{
    FilePath = $resolved
    PassThru = $true
    WorkingDirectory = $scriptParentDir
  }
  if (-not [bool]$effectiveNoRedirectLogs) {
    $startArgs["RedirectStandardOutput"] = $resolvedStdoutLogPath
    $startArgs["RedirectStandardError"] = $resolvedStderrLogPath
  }
  $proc = Start-Process @startArgs
  Write-EventLogLine `
    -eventLogPath $resolvedEventLogPath `
    -level "INFO" `
    -message ("launch_started pid={0}" -f $proc.Id)

  if ($DetachedProbeMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $DetachedProbeMilliseconds
    $proc.Refresh()
    if ($proc.HasExited) {
      $detachedExitCode = [int]$proc.ExitCode
      if ($detachedExitCode -eq 0) {
        Write-EventLogLine `
          -eventLogPath $resolvedEventLogPath `
          -level "ERROR" `
          -message ("detached_process_exited_early exit={0}" -f $detachedExitCode)
      } else {
        Write-EventLogLine `
          -eventLogPath $resolvedEventLogPath `
          -level "ERROR" `
          -message ("detached_process_exited_nonzero exit={0}" -f $detachedExitCode)
      }
      Write-Output ("NATIVE_RUNTIME_DETACHED_HEALTHY=False")
      Write-Output ("NATIVE_RUNTIME_EXIT={0}" -f $detachedExitCode)
      Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
      Write-Output ("NATIVE_RUNTIME_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
      Write-Output ("NATIVE_RUNTIME_LOG_MODE={0}" -f $logMode)
      if (-not [bool]$effectiveNoRedirectLogs) {
        Write-Output ("NATIVE_RUNTIME_STDOUT_LOG={0}" -f $resolvedStdoutLogPath)
        Write-Output ("NATIVE_RUNTIME_STDERR_LOG={0}" -f $resolvedStderrLogPath)
      }
      Write-Output ("NATIVE_RUNTIME_EVENT_LOG={0}" -f $resolvedEventLogPath)
      if ($detachedExitCode -ne 0) {
        exit $detachedExitCode
      }
      exit 1
    }
  }

  Write-Output ("NATIVE_RUNTIME_DETACHED_HEALTHY=True")
  Write-Output ("NATIVE_RUNTIME_STARTED_PID={0}" -f $proc.Id)
  Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
  Write-Output ("NATIVE_RUNTIME_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
  Write-Output ("NATIVE_RUNTIME_LOG_MODE={0}" -f $logMode)
  if (-not [bool]$effectiveNoRedirectLogs) {
    Write-Output ("NATIVE_RUNTIME_STDOUT_LOG={0}" -f $resolvedStdoutLogPath)
    Write-Output ("NATIVE_RUNTIME_STDERR_LOG={0}" -f $resolvedStderrLogPath)
  }
  Write-Output ("NATIVE_RUNTIME_EVENT_LOG={0}" -f $resolvedEventLogPath)
  exit 0
}

$startArgs = @{
  FilePath = $resolved
  PassThru = $true
  Wait = $true
  WorkingDirectory = $scriptParentDir
}
if (-not [bool]$effectiveNoRedirectLogs) {
  $startArgs["RedirectStandardOutput"] = $resolvedStdoutLogPath
  $startArgs["RedirectStandardError"] = $resolvedStderrLogPath
} else {
  $startArgs["NoNewWindow"] = $true
}
$proc = Start-Process @startArgs
$exitCode = [int]$proc.ExitCode
if ($exitCode -eq 0) {
  Write-EventLogLine `
    -eventLogPath $resolvedEventLogPath `
    -level "INFO" `
    -message ("process_exited_ok exit={0}" -f $exitCode)
} else {
  Write-EventLogLine `
    -eventLogPath $resolvedEventLogPath `
    -level "ERROR" `
    -message ("process_exited_nonzero exit={0}" -f $exitCode)
}
Write-Output ("NATIVE_RUNTIME_EXIT={0}" -f $exitCode)
Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
Write-Output ("NATIVE_RUNTIME_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
Write-Output ("NATIVE_RUNTIME_LOG_MODE={0}" -f $logMode)
if (-not [bool]$effectiveNoRedirectLogs) {
  Write-Output ("NATIVE_RUNTIME_STDOUT_LOG={0}" -f $resolvedStdoutLogPath)
  Write-Output ("NATIVE_RUNTIME_STDERR_LOG={0}" -f $resolvedStderrLogPath)
}
Write-Output ("NATIVE_RUNTIME_EVENT_LOG={0}" -f $resolvedEventLogPath)
exit $exitCode
