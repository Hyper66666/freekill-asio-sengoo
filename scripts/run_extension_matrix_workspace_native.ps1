param(
  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [string]$MatrixScriptPath = "scripts/run_extension_matrix_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$TargetsOutputPath = ".tmp/runtime_host/extension_matrix_workspace_targets.json",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/extension_matrix_workspace_report.json"
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

function Get-PackageRoots([string]$packagesRootAbs) {
  $roots = New-Object System.Collections.Generic.List[string]
  $nestedRoot = Join-Path $packagesRootAbs "packages"
  if (Test-Path $nestedRoot) {
    [void]$roots.Add((Resolve-Path $nestedRoot).Path)
  }
  if (Test-Path $packagesRootAbs) {
    [void]$roots.Add((Resolve-Path $packagesRootAbs).Path)
  }
  return @($roots | Select-Object -Unique)
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

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $repoRoot
$resolvedMatrixScriptPath = Resolve-AbsolutePath -path $MatrixScriptPath -baseDir $repoRoot
$resolvedTargetsOutputPath = Resolve-AbsolutePath -path $TargetsOutputPath -baseDir $repoRoot
$resolvedOutputPath = Resolve-AbsolutePath -path $OutputPath -baseDir $repoRoot

if (-not (Test-Path $resolvedPackagesRoot)) {
  throw "packages root not found: $resolvedPackagesRoot"
}
if (-not (Test-Path $resolvedMatrixScriptPath)) {
  throw "extension matrix script not found: $resolvedMatrixScriptPath"
}

$records = New-Object System.Collections.Generic.List[object]
$seen = @{}
foreach ($root in @(Get-PackageRoots $resolvedPackagesRoot)) {
  $dirs = @(Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue)
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
    $records.Add([ordered]@{
      name = $name
      url = [System.IO.Path]::GetFullPath($dir.FullName)
      supports_disable = ($name -ne "freekill-core")
      priority = "P1"
      source = "workspace"
      entry_kind = [string]$entry.entry_kind
      source_root = $root
    }) | Out-Null
    $seen[$name] = $true
  }
}

if ($records.Count -eq 0) {
  throw "no discoverable extensions found under packages roots"
}

$targets = [ordered]@{
  schema_version = 1
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  packages_root = $resolvedPackagesRoot
  target_count = $records.Count
  targets = @($records | Sort-Object -Property name)
}

Ensure-ParentDir $resolvedTargetsOutputPath
$targets | ConvertTo-Json -Depth 10 | Set-Content -Path $resolvedTargetsOutputPath -Encoding UTF8

& powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedMatrixScriptPath `
  -TargetsPath $resolvedTargetsOutputPath `
  -OutputPath $resolvedOutputPath
$matrixExitCode = [int]$LASTEXITCODE
if ($matrixExitCode -ne 0) {
  throw ("workspace extension matrix failed with exit code {0}" -f $matrixExitCode)
}

Write-Output "EXTENSION_MATRIX_WORKSPACE_OK=True"
Write-Output ("EXTENSION_MATRIX_WORKSPACE_TARGETS={0}" -f (Resolve-Path $resolvedTargetsOutputPath).Path)
Write-Output ("EXTENSION_MATRIX_WORKSPACE_REPORT={0}" -f (Resolve-Path $resolvedOutputPath).Path)
