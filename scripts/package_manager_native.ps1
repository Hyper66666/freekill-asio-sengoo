param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("install", "remove", "pkgs", "syncpkgs", "enable", "disable", "upgrade", "init")]
  [string]$Command,

  [Parameter(Mandatory = $false)]
  [string]$Name = "",

  [Parameter(Mandatory = $false)]
  [string]$Url = "",

  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [string]$RegistryFileName = "packages.registry.json",

  [Parameter(Mandatory = $false)]
  [switch]$AsJson,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/package_manager_native_last.json",

  [Parameter(Mandatory = $false)]
  [string]$ExtensionSyncRegistryPath = ".tmp/runtime_host/extension_sync.registry.json",

  [Parameter(Mandatory = $false)]
  [switch]$SkipExtensionSyncRegistryRefresh
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Reason-Ok() { 0 }
function Reason-UnknownFailure() { 9300 }
function Reason-CoreDisableForbidden() { 9301 }
function Reason-UpgradePartialFailure() { 9302 }
function Reason-MissingRequiredArgument() { 9303 }
function Reason-InvalidPackageName() { 9304 }
function Reason-GitUnavailable() { 9305 }
function Reason-PackageMissing() { 9306 }

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

function Ensure-PackagesLayout([string]$packagesDir) {
  if (-not (Test-Path $packagesDir)) {
    New-Item -ItemType Directory -Path $packagesDir -Force | Out-Null
  }
  $initSql = Join-Path $packagesDir "init.sql"
  if (-not (Test-Path $initSql)) {
    @"
CREATE TABLE IF NOT EXISTS packages (
  name VARCHAR(128),
  url VARCHAR(255),
  hash CHAR(40),
  enabled BOOLEAN
);
"@ | Set-Content -Path $initSql -Encoding UTF8
  }
}

function Normalize-PackageNameFromUrl([string]$packageUrl) {
  $trimmed = $packageUrl.Trim()
  while ($trimmed.EndsWith("/")) {
    $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
  }
  $leaf = [System.IO.Path]::GetFileName($trimmed)
  if ($leaf.EndsWith(".git")) {
    $leaf = $leaf.Substring(0, $leaf.Length - 4)
  }
  return $leaf
}

function Resolve-LocalPackageSourcePath([string]$packageUrl) {
  if ([string]::IsNullOrWhiteSpace($packageUrl)) {
    return ""
  }
  $trimmed = $packageUrl.Trim()
  $candidate = ""
  if ($trimmed.StartsWith("file://")) {
    try {
      $uri = [System.Uri]::new($trimmed)
      if ($uri.IsFile) {
        $candidate = $uri.LocalPath
      }
    } catch {
      $candidate = ""
    }
  } elseif (Test-Path $trimmed) {
    $candidate = $trimmed
  }
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    return ""
  }
  return [System.IO.Path]::GetFullPath($candidate)
}

function Load-Registry([string]$registryPath) {
  if (-not (Test-Path $registryPath)) {
    return @()
  }
  $raw = Get-Content -Raw -Path $registryPath
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }
  $parsed = $raw | ConvertFrom-Json
  if ($null -eq $parsed) {
    return @()
  }
  $items = @()
  if ($parsed -is [System.Array]) {
    $items = [object[]]$parsed
  } else {
    $items = @($parsed)
  }
  $normalized = @()
  foreach ($item in $items) {
    $normalized += [pscustomobject]@{
      name = [string]$item.name
      url = [string]$item.url
      hash = [string]$item.hash
      enabled = [bool]$item.enabled
    }
  }
  return $normalized
}

function Save-Registry([string]$registryPath, [object[]]$registry) {
  $sorted = $registry | Sort-Object -Property name
  Ensure-ParentDir $registryPath
  if ($null -eq $sorted -or @($sorted).Count -eq 0) {
    "[]" | Set-Content -Path $registryPath -Encoding UTF8
  } else {
    @($sorted) | ConvertTo-Json -Depth 6 | Set-Content -Path $registryPath -Encoding UTF8
  }
}

function Get-RecordIndex([object[]]$registry, [string]$name) {
  for ($i = 0; $i -lt $registry.Count; $i++) {
    if ([string]$registry[$i].name -eq $name) {
      return $i
    }
  }
  return -1
}

function Get-GitHeadHash([string]$packageDir) {
  if (-not (Test-Path (Join-Path $packageDir ".git"))) {
    return "0000000000000000000000000000000000000000"
  }
  $hash = (& git -C $packageDir rev-parse HEAD 2>$null).Trim()
  if ([string]::IsNullOrWhiteSpace($hash)) {
    return "0000000000000000000000000000000000000000"
  }
  return $hash
}

function Is-GitAvailable() {
  $git = Get-Command git -ErrorAction SilentlyContinue
  return ($null -ne $git)
}

function New-PackageFailure([int]$reasonCode, [string]$message, [hashtable]$extraDetails) {
  $details = @{}
  if ($null -ne $extraDetails) {
    foreach ($key in $extraDetails.Keys) {
      $details[$key] = $extraDetails[$key]
    }
  }
  return [pscustomobject]@{
    reason_code = $reasonCode
    message = $message
    details = $details
  }
}

function Sync-DisabledPacksSnapshot([string]$packagesDir, [object[]]$registry) {
  $disabled = @($registry | Where-Object { -not [bool]$_.enabled } | Select-Object -ExpandProperty name | Sort-Object)
  $snapshotPath = Join-Path $packagesDir "disabled_packs.json"
  $disabled | ConvertTo-Json | Set-Content -Path $snapshotPath -Encoding UTF8
}

function Emit-Report(
  [string]$outputPath,
  [string]$commandName,
  [bool]$ok,
  [int]$reasonCode,
  [string]$packagesDir,
  [string]$registryPath,
  [object[]]$registry,
  [hashtable]$details
) {
  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    command = $commandName
    ok = $ok
    reason_code = $reasonCode
    packages_root = $packagesDir
    registry_path = $registryPath
    package_count = $registry.Count
    enabled_count = @($registry | Where-Object { [bool]$_.enabled }).Count
    disabled_count = @($registry | Where-Object { -not [bool]$_.enabled }).Count
    details = $details
  }
  Ensure-ParentDir $outputPath
  $report | ConvertTo-Json -Depth 8 | Set-Content -Path $outputPath -Encoding UTF8
  return $report
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $repoRoot
$resolvedRegistryPath = Join-Path $resolvedPackagesRoot $RegistryFileName

Ensure-PackagesLayout $resolvedPackagesRoot
$registry = @(Load-Registry $resolvedRegistryPath)
$details = @{}
$failure = $null

try {
  switch ($Command) {
    "init" {
      $details["message"] = "packages layout initialized"
    }
    "install" {
      if ([string]::IsNullOrWhiteSpace($Url)) {
        $failure = New-PackageFailure (Reason-MissingRequiredArgument) "install command requires -Url" @{}
        break
      }
      if (-not (Is-GitAvailable)) {
        $failure = New-PackageFailure (Reason-GitUnavailable) "git command not found" @{}
        break
      }
      $pkgName = Normalize-PackageNameFromUrl $Url
      if ([string]::IsNullOrWhiteSpace($pkgName)) {
        $failure = New-PackageFailure (Reason-InvalidPackageName) ("cannot resolve package name from url: {0}" -f $Url) @{}
        break
      }
      $targetDir = Join-Path $resolvedPackagesRoot $pkgName
      $sourceMode = "git_clone"
      if (-not (Test-Path $targetDir)) {
        $localSourcePath = Resolve-LocalPackageSourcePath $Url
        if (-not [string]::IsNullOrWhiteSpace($localSourcePath) -and (Test-Path $localSourcePath)) {
          Copy-Item -Path $localSourcePath -Destination $targetDir -Recurse -Force
          $sourceMode = "local_copy"
        } else {
          & git clone $Url $targetDir | Out-Null
          if ($LASTEXITCODE -ne 0) {
            $failure = New-PackageFailure (Reason-UnknownFailure) ("git clone failed: {0}" -f $Url) @{
              package = $pkgName
              url = $Url
            }
            break
          }
        }
      } else {
        $gitDir = Join-Path $targetDir ".git"
        if (-not (Test-Path $gitDir)) {
          $failure = New-PackageFailure (Reason-PackageMissing) ("existing package path is not a git repository: {0}" -f $targetDir) @{
            package = $pkgName
          }
          break
        }
      }
      $hash = Get-GitHeadHash $targetDir
      $idx = Get-RecordIndex $registry $pkgName
      if ($idx -ge 0) {
        $registry[$idx] = [pscustomobject]@{
          name = $pkgName
          url = $Url
          hash = $hash
          enabled = $true
        }
      } else {
        $registry += [pscustomobject]@{
          name = $pkgName
          url = $Url
          hash = $hash
          enabled = $true
        }
      }
      $details["package"] = $pkgName
      $details["hash"] = $hash
      $details["path"] = $targetDir
      $details["source_mode"] = $sourceMode
    }
    "remove" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failure = New-PackageFailure (Reason-MissingRequiredArgument) "remove command requires -Name" @{}
        break
      }
      $pkgName = $Name.Trim()
      $idx = Get-RecordIndex $registry $pkgName
      $targetDir = Join-Path $resolvedPackagesRoot $pkgName
      if ($idx -lt 0 -and -not (Test-Path $targetDir)) {
        $failure = New-PackageFailure (Reason-PackageMissing) ("package not found: {0}" -f $pkgName) @{
          package = $pkgName
        }
        break
      }
      $removedFromRegistry = $false
      if ($idx -ge 0) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $registry) { [void]$list.Add($item) }
        $list.RemoveAt($idx)
        $registry = @($list.ToArray())
        $removedFromRegistry = $true
      }
      if (Test-Path $targetDir) {
        Remove-Item -Recurse -Force $targetDir
      }
      $details["package"] = $pkgName
      $details["removed_from_registry"] = $removedFromRegistry
      $details["removed_path"] = $targetDir
    }
    "pkgs" {
      # no mutation
      $details["packages"] = @($registry | Sort-Object -Property name)
    }
    "syncpkgs" {
      $dirs = @(Get-ChildItem -Path $resolvedPackagesRoot -Directory -Force | Where-Object { $_.Name -notlike ".*" })
      foreach ($dir in $dirs) {
        $pkgName = $dir.Name
        $idx = Get-RecordIndex $registry $pkgName
        $hash = Get-GitHeadHash $dir.FullName
        if ($idx -ge 0) {
          $registry[$idx] = [pscustomobject]@{
            name = $pkgName
            url = [string]$registry[$idx].url
            hash = $hash
            enabled = [bool]$registry[$idx].enabled
          }
        } else {
          $registry += [pscustomobject]@{
            name = $pkgName
            url = ""
            hash = $hash
            enabled = $true
          }
        }
      }
      $details["scanned_dir_count"] = $dirs.Count
    }
    "enable" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failure = New-PackageFailure (Reason-MissingRequiredArgument) "enable command requires -Name" @{}
        break
      }
      $pkgName = $Name.Trim()
      $targetDir = Join-Path $resolvedPackagesRoot $pkgName
      if (-not (Test-Path $targetDir)) {
        $failure = New-PackageFailure (Reason-PackageMissing) ("package directory missing: {0}" -f $targetDir) @{
          package = $pkgName
        }
        break
      }
      $idx = Get-RecordIndex $registry $pkgName
      $hash = Get-GitHeadHash $targetDir
      if ($idx -ge 0) {
        $registry[$idx] = [pscustomobject]@{
          name = $pkgName
          url = [string]$registry[$idx].url
          hash = $hash
          enabled = $true
        }
      } else {
        $registry += [pscustomobject]@{
          name = $pkgName
          url = ""
          hash = $hash
          enabled = $true
        }
      }
      $details["package"] = $pkgName
    }
    "disable" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failure = New-PackageFailure (Reason-MissingRequiredArgument) "disable command requires -Name" @{}
        break
      }
      $pkgName = $Name.Trim()
      if ($pkgName -eq "freekill-core") {
        $failure = New-PackageFailure (Reason-CoreDisableForbidden) "package 'freekill-core' cannot be disabled" @{
          package = $pkgName
        }
        break
      }
      $targetDir = Join-Path $resolvedPackagesRoot $pkgName
      if (-not (Test-Path $targetDir)) {
        $failure = New-PackageFailure (Reason-PackageMissing) ("package directory missing: {0}" -f $targetDir) @{
          package = $pkgName
        }
        break
      }
      $idx = Get-RecordIndex $registry $pkgName
      $hash = Get-GitHeadHash $targetDir
      if ($idx -ge 0) {
        $registry[$idx] = [pscustomobject]@{
          name = $pkgName
          url = [string]$registry[$idx].url
          hash = $hash
          enabled = $false
        }
      } else {
        $registry += [pscustomobject]@{
          name = $pkgName
          url = ""
          hash = $hash
          enabled = $false
        }
      }
      $details["package"] = $pkgName
    }
    "upgrade" {
      if (-not (Is-GitAvailable)) {
        $failure = New-PackageFailure (Reason-GitUnavailable) "git command not found" @{}
        break
      }
      $targets = @()
      if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $targets += $Name.Trim()
      } else {
        $targets += @($registry | Sort-Object -Property name | Select-Object -ExpandProperty name)
      }
      $upgraded = New-Object System.Collections.Generic.List[string]
      $failed = New-Object System.Collections.Generic.List[string]
      foreach ($pkgName in @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $targetDir = Join-Path $resolvedPackagesRoot $pkgName
        if (-not (Test-Path $targetDir)) {
          [void]$failed.Add($pkgName)
          continue
        }
        if (-not (Test-Path (Join-Path $targetDir ".git"))) {
          [void]$failed.Add($pkgName)
          continue
        }
        cmd.exe /c "git -C ""$targetDir"" pull --ff-only 1>nul 2>nul" | Out-Null
        if ($LASTEXITCODE -eq 0) {
          [void]$upgraded.Add($pkgName)
          $idx = Get-RecordIndex $registry $pkgName
          $hash = Get-GitHeadHash $targetDir
          if ($idx -ge 0) {
            $registry[$idx] = [pscustomobject]@{
              name = $pkgName
              url = [string]$registry[$idx].url
              hash = $hash
              enabled = [bool]$registry[$idx].enabled
            }
          } else {
            $registry += [pscustomobject]@{
              name = $pkgName
              url = ""
              hash = $hash
              enabled = $true
            }
          }
        } else {
          [void]$failed.Add($pkgName)
        }
      }
      $details["upgraded"] = @($upgraded.ToArray() | Sort-Object)
      $details["failed"] = @($failed.ToArray() | Sort-Object)
      if ($failed.Count -gt 0) {
        $failure = New-PackageFailure (Reason-UpgradePartialFailure) "upgrade completed with partial failures" @{
          failed_count = $failed.Count
        }
      }
    }
  }
} catch {
  if ($null -eq $failure) {
    $failure = New-PackageFailure (Reason-UnknownFailure) $_.Exception.Message @{}
  }
}

$ok = ($null -eq $failure)
$reasonCode = if ($ok) { Reason-Ok } else { [int]$failure.reason_code }
if (-not $ok) {
  $details["error"] = [string]$failure.message
  foreach ($key in $failure.details.Keys) {
    if (-not $details.ContainsKey($key)) {
      $details[$key] = $failure.details[$key]
    }
  }
}

Save-Registry $resolvedRegistryPath $registry
Sync-DisabledPacksSnapshot $resolvedPackagesRoot $registry

if (-not [bool]$SkipExtensionSyncRegistryRefresh) {
  $refreshScriptPath = Resolve-AbsolutePath -path "scripts/refresh_extension_sync_registry.ps1" -baseDir $repoRoot
  $resolvedExtensionSyncRegistryPath = Resolve-AbsolutePath -path $ExtensionSyncRegistryPath -baseDir $repoRoot
  if (Test-Path $refreshScriptPath) {
    try {
      $refreshJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $refreshScriptPath `
        -PackagesRoot $resolvedPackagesRoot `
        -OutputPath $resolvedExtensionSyncRegistryPath `
        -AsJson
      $refreshExit = [int]$LASTEXITCODE
      if ($refreshExit -eq 0 -and -not [string]::IsNullOrWhiteSpace(($refreshJson -join [Environment]::NewLine))) {
        $refreshReport = (($refreshJson -join [Environment]::NewLine).Trim() | ConvertFrom-Json)
        $details["extension_sync_registry_refreshed"] = $true
        $details["extension_sync_registry_path"] = [string]$refreshReport.output_path
        $details["extension_sync_registry_count"] = [int]$refreshReport.extension_count
      } else {
        $details["extension_sync_registry_refreshed"] = $false
        $details["extension_sync_registry_error"] = ("refresh script exited with code {0}" -f $refreshExit)
      }
    } catch {
      $details["extension_sync_registry_refreshed"] = $false
      $details["extension_sync_registry_error"] = $_.Exception.Message
    }
  } else {
    $details["extension_sync_registry_refreshed"] = $false
    $details["extension_sync_registry_error"] = ("refresh script not found: {0}" -f $refreshScriptPath)
  }
}

$report = Emit-Report $OutputPath $Command $ok $reasonCode $resolvedPackagesRoot $resolvedRegistryPath $registry $details

if ($AsJson) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Output ("PACKAGE_CMD={0}" -f $Command)
  Write-Output ("PACKAGE_OK={0}" -f $ok)
  Write-Output ("PACKAGE_REASON_CODE={0}" -f $reasonCode)
  Write-Output ("PACKAGE_ROOT={0}" -f $resolvedPackagesRoot)
  Write-Output ("PACKAGE_REGISTRY={0}" -f $resolvedRegistryPath)
  Write-Output ("PACKAGE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)
  Write-Output ("PACKAGE_COUNT={0}" -f $report.package_count)
  Write-Output ("PACKAGE_ENABLED={0}" -f $report.enabled_count)
  Write-Output ("PACKAGE_DISABLED={0}" -f $report.disabled_count)
  if ($Command -eq "pkgs") {
    Write-Output "PACKAGE_LIST_BEGIN"
    foreach ($item in ($registry | Sort-Object -Property name)) {
      $enabledText = if ([bool]$item.enabled) { "1" } else { "0" }
      Write-Output ("{0}`t{1}`t{2}`t{3}" -f $item.name, $item.hash, $enabledText, $item.url)
    }
    Write-Output "PACKAGE_LIST_END"
  }
}

if (-not $ok) {
  exit 1
}
