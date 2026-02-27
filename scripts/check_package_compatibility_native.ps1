param(
  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [string]$RegistryFileName = "packages.registry.json",

  [Parameter(Mandatory = $false)]
  [bool]$RequireFreeKillCore = $true,

  [Parameter(Mandatory = $false)]
  [string]$RequiredCoreEntryRelativePath = "lua/server/rpc/entry.lua",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/package_compatibility_report.json"
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

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $repoRoot
$registryPath = Join-Path $resolvedPackagesRoot $RegistryFileName
$initSqlPath = Join-Path $resolvedPackagesRoot "init.sql"
$coreRoot = Join-Path $resolvedPackagesRoot "freekill-core"
$coreEntry = Join-Path $coreRoot $RequiredCoreEntryRelativePath

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$registrySchemaOk = $true
$registryCount = 0

if (-not (Test-Path $resolvedPackagesRoot)) {
  [void]$errors.Add("missing packages root: $resolvedPackagesRoot")
}
if (-not (Test-Path $initSqlPath)) {
  [void]$errors.Add("missing packages init.sql: $initSqlPath")
}
if (-not (Test-Path $registryPath)) {
  [void]$warnings.Add("registry file missing: $registryPath")
  $registrySchemaOk = $false
} else {
  try {
    $registryRaw = Get-Content -Raw -Path $registryPath
    if (-not [string]::IsNullOrWhiteSpace($registryRaw)) {
      $parsed = $registryRaw | ConvertFrom-Json
      $records = @()
      if ($null -eq $parsed) {
        $records = @()
      } elseif ($parsed -is [System.Array]) {
        $records = [object[]]$parsed
      } else {
        $records = @($parsed)
      }
      $registryCount = $records.Count
      foreach ($record in $records) {
        if ($null -eq $record.name -or $null -eq $record.url -or $null -eq $record.hash -or $null -eq $record.enabled) {
          $registrySchemaOk = $false
          [void]$warnings.Add("registry record missing one of required fields: name/url/hash/enabled")
          break
        }
      }
    }
  } catch {
    $registrySchemaOk = $false
    [void]$warnings.Add("failed to parse registry json: $($_.Exception.Message)")
  }
}

if ($RequireFreeKillCore) {
  if (-not (Test-Path $coreRoot)) {
    [void]$errors.Add("missing required package directory: $coreRoot")
  }
  if (-not (Test-Path $coreEntry)) {
    [void]$errors.Add("missing required freekill-core entry: $coreEntry")
  }
}

$pass = ($errors.Count -eq 0)
$report = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = $pass
  packages_root = $resolvedPackagesRoot
  init_sql_path = $initSqlPath
  registry_path = $registryPath
  registry_schema_ok = $registrySchemaOk
  registry_count = $registryCount
  require_freekill_core = $RequireFreeKillCore
  freekill_core_path = $coreRoot
  freekill_core_entry = $coreEntry
  errors = @($errors.ToArray())
  warnings = @($warnings.ToArray())
}

Ensure-ParentDir $OutputPath
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("PACKAGE_COMPAT_OK={0}" -f $pass)
Write-Output ("PACKAGE_COMPAT_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $pass) {
  exit 1
}
