param(
  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/extension_sync.registry.json",

  [Parameter(Mandatory = $false)]
  [switch]$AsJson
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

function Build-ExtensionRegistryRecords([string]$packagesRootPath) {
  $candidateRoots = New-Object System.Collections.Generic.List[string]
  $nestedRoot = Join-Path $packagesRootPath "packages"
  if (Test-Path $nestedRoot) {
    [void]$candidateRoots.Add($nestedRoot)
  }
  [void]$candidateRoots.Add($packagesRootPath)

  $seen = @{}
  $resolvedRoots = New-Object System.Collections.Generic.List[string]
  $records = New-Object System.Collections.Generic.List[object]
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

  return [ordered]@{
    records = @($records | Sort-Object -Property name)
    roots = @($resolvedRoots | Sort-Object -Unique)
  }
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $repoRoot
$resolvedOutputPath = Resolve-AbsolutePath -path $OutputPath -baseDir $repoRoot

if (-not (Test-Path $resolvedPackagesRoot)) {
  throw "packages root not found: $resolvedPackagesRoot"
}

$build = Build-ExtensionRegistryRecords -packagesRootPath $resolvedPackagesRoot
$records = @($build.records)
$recordJsonItems = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 6 -Compress })
$registryJson = if ($recordJsonItems.Count -eq 0) {
  "[]"
} else {
  "[" + ($recordJsonItems -join ",") + "]"
}

Ensure-ParentDir $resolvedOutputPath
Set-Content -Path $resolvedOutputPath -Encoding UTF8 -Value $registryJson

$report = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  packages_root = $resolvedPackagesRoot
  output_path = $resolvedOutputPath
  extension_count = $records.Count
  extension_names = @($records | ForEach-Object { [string]$_.name })
  scan_roots = @($build.roots)
}

if ($AsJson) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Output ("EXT_SYNC_REGISTRY_UPDATED=True")
  Write-Output ("EXT_SYNC_REGISTRY_OUTPUT={0}" -f $resolvedOutputPath)
  Write-Output ("EXT_SYNC_REGISTRY_COUNT={0}" -f $records.Count)
}
