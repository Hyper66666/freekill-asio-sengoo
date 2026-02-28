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
  [int]$DetachedProbeMilliseconds = 1200,

  [Parameter(Mandatory = $false)]
  [string]$ExtensionSyncRegistryPath = "",

  [Parameter(Mandatory = $false)]
  [switch]$DisableAutoExtensionSyncRegistry
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

function Resolve-ExtensionEntry([string]$packageDir) {
  $candidates = @(
    [ordered]@{ kind = "rpc_entry"; path = (Join-Path $packageDir "lua/server/rpc/entry.lua") },
    [ordered]@{ kind = "package_init"; path = (Join-Path $packageDir "init.lua") },
    [ordered]@{ kind = "lua_init"; path = (Join-Path $packageDir "lua/init.lua") }
  )
  foreach ($candidate in $candidates) {
    if (Test-Path ([string]$candidate.path)) {
      return [ordered]@{
        entry_path = [string]$candidate.path
        entry_kind = [string]$candidate.kind
      }
    }
  }
  return $null
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

function Build-ExtensionSyncRegistry([string]$packagesRootPath, [string]$outputPath) {
  $candidateRoots = New-Object System.Collections.Generic.List[string]
  $nestedRoot = Join-Path $packagesRootPath "packages"
  if (Test-Path $nestedRoot) {
    [void]$candidateRoots.Add($nestedRoot)
  }
  [void]$candidateRoots.Add($packagesRootPath)

  $seen = @{}
  $records = New-Object System.Collections.Generic.List[object]
  $resolvedRoots = New-Object System.Collections.Generic.List[string]
  foreach ($root in $candidateRoots) {
    if (-not (Test-Path $root)) {
      continue
    }
    $resolvedRoot = (Resolve-Path $root).Path
    [void]$resolvedRoots.Add($resolvedRoot)
    $dirs = @(Get-ChildItem -Path $resolvedRoot -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($dir in $dirs) {
      $name = [string]$dir.Name
      if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith(".")) {
        continue
      }
      if ($seen.ContainsKey($name)) {
        continue
      }
      $entry = Resolve-ExtensionEntry -packageDir $dir.FullName
      if ($null -eq $entry) {
        continue
      }
      $entryPath = [string]$entry.entry_path
      $entryKind = [string]$entry.entry_kind
      $entryHash = (Get-FileHash -Algorithm SHA256 -Path $entryPath).Hash.ToLowerInvariant()
      $record = [ordered]@{
        name = $name
        enabled = $true
        builtin = ($name -eq "freekill-core")
        source_root = $resolvedRoot
        package_path = $dir.FullName
        entry = $entryPath
        entry_kind = $entryKind
        hash = $entryHash
      }
      [void]$records.Add($record)
      $seen[$name] = $true
    }
  }

  $sortedRecords = @($records | Sort-Object -Property name)
  $jsonRecords = @($sortedRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress })
  $registryJson = if ($jsonRecords.Count -eq 0) {
    "[]"
  } else {
    "[" + ($jsonRecords -join ",") + "]"
  }
  Ensure-ParentDir $outputPath
  Set-Content -Path $outputPath -Encoding UTF8 -Value $registryJson

  return [ordered]@{
    registry_path = (Resolve-Path $outputPath).Path
    extension_count = $sortedRecords.Count
    extension_names = @($sortedRecords | ForEach-Object { [string]$_.name })
    roots = @($resolvedRoots | Sort-Object -Unique)
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

$resolvedExtensionSyncRegistryPath = if ([string]::IsNullOrWhiteSpace($ExtensionSyncRegistryPath)) {
  Join-Path $resolvedLogDir "extension_sync.registry.json"
} else {
  Resolve-AbsolutePath -path $ExtensionSyncRegistryPath -baseDir $scriptParentDir
}
$extensionSyncRegistry = $null
if (-not [bool]$DisableAutoExtensionSyncRegistry) {
  $refreshScriptPath = Resolve-AbsolutePath -path "scripts/refresh_extension_sync_registry.ps1" -baseDir $scriptParentDir
  if (Test-Path $refreshScriptPath) {
    $refreshOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshScriptPath `
      -PackagesRoot $resolvedPackagesRoot `
      -OutputPath $resolvedExtensionSyncRegistryPath `
      -AsJson
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($refreshOutput -join [Environment]::NewLine))) {
      $refreshReport = (($refreshOutput -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
      $extensionSyncRegistry = [ordered]@{
        registry_path = [string]$refreshReport.output_path
        extension_count = [int]$refreshReport.extension_count
        extension_names = @($refreshReport.extension_names)
        roots = @($refreshReport.scan_roots)
      }
    } else {
      throw "extension sync registry refresh failed"
    }
  } else {
    $extensionSyncRegistry = Build-ExtensionSyncRegistry `
      -packagesRootPath $resolvedPackagesRoot `
      -outputPath $resolvedExtensionSyncRegistryPath
  }
}

$logMode = if ([bool]$effectiveNoRedirectLogs) { "none" } else { "file" }
Write-EventLogLine `
  -eventLogPath $resolvedEventLogPath `
  -level "INFO" `
  -message ("launch_requested detached={0}; binary={1}; packages_root={2}; log_mode={3}" -f [bool]$Detached, $resolved, $resolvedPackagesRoot, $logMode)

if ($null -ne $extensionSyncRegistry) {
  Write-EventLogLine `
    -eventLogPath $resolvedEventLogPath `
    -level "INFO" `
    -message ("extension_sync_registry_ready count={0}; path={1}" -f [int]$extensionSyncRegistry.extension_count, [string]$extensionSyncRegistry.registry_path)
}

$originalExtensionRegistryEnv = [string]$env:SENGOO_EXTENSION_REGISTRY
$originalCoreEntryEnv = [string]$env:SENGOO_EXTENSION_CORE_ENTRY
$resolvedCoreEntryPath = Join-Path $resolvedPackagesRoot "packages/freekill-core/lua/server/rpc/entry.lua"
if (-not (Test-Path $resolvedCoreEntryPath)) {
  $resolvedCoreEntryPath = Join-Path $resolvedPackagesRoot "freekill-core/lua/server/rpc/entry.lua"
}
if ($null -ne $extensionSyncRegistry) {
  $env:SENGOO_EXTENSION_REGISTRY = [string]$extensionSyncRegistry.registry_path
}
if (Test-Path $resolvedCoreEntryPath) {
  $env:SENGOO_EXTENSION_CORE_ENTRY = $resolvedCoreEntryPath
}

try {
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
        if ($null -ne $extensionSyncRegistry) {
          Write-Output ("NATIVE_RUNTIME_EXTENSION_REGISTRY={0}" -f [string]$extensionSyncRegistry.registry_path)
          Write-Output ("NATIVE_RUNTIME_EXTENSION_COUNT={0}" -f [int]$extensionSyncRegistry.extension_count)
        }
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
    if ($null -ne $extensionSyncRegistry) {
      Write-Output ("NATIVE_RUNTIME_EXTENSION_REGISTRY={0}" -f [string]$extensionSyncRegistry.registry_path)
      Write-Output ("NATIVE_RUNTIME_EXTENSION_COUNT={0}" -f [int]$extensionSyncRegistry.extension_count)
    }
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
  if ($null -ne $extensionSyncRegistry) {
    Write-Output ("NATIVE_RUNTIME_EXTENSION_REGISTRY={0}" -f [string]$extensionSyncRegistry.registry_path)
    Write-Output ("NATIVE_RUNTIME_EXTENSION_COUNT={0}" -f [int]$extensionSyncRegistry.extension_count)
  }
  if (-not [bool]$effectiveNoRedirectLogs) {
    Write-Output ("NATIVE_RUNTIME_STDOUT_LOG={0}" -f $resolvedStdoutLogPath)
    Write-Output ("NATIVE_RUNTIME_STDERR_LOG={0}" -f $resolvedStderrLogPath)
  }
  Write-Output ("NATIVE_RUNTIME_EVENT_LOG={0}" -f $resolvedEventLogPath)
  exit $exitCode
} finally {
  if ([string]::IsNullOrWhiteSpace($originalExtensionRegistryEnv)) {
    Remove-Item Env:SENGOO_EXTENSION_REGISTRY -ErrorAction SilentlyContinue
  } else {
    $env:SENGOO_EXTENSION_REGISTRY = $originalExtensionRegistryEnv
  }
  if ([string]::IsNullOrWhiteSpace($originalCoreEntryEnv)) {
    Remove-Item Env:SENGOO_EXTENSION_CORE_ENTRY -ErrorAction SilentlyContinue
  } else {
    $env:SENGOO_EXTENSION_CORE_ENTRY = $originalCoreEntryEnv
  }
}
