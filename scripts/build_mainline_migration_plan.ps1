param(
  [Parameter(Mandatory = $false)]
  [string]$RewriteRoot = ".",

  [Parameter(Mandatory = $false)]
  [string]$MainlineRoot = "..",

  [Parameter(Mandatory = $false)]
  [string[]]$IncludePaths = @(
    "src",
    "tests",
    "docs",
    "scripts",
    "openspec",
    "README.md"
  ),

  [Parameter(Mandatory = $false)]
  [string[]]$ExcludePatterns = @(
    ".git/*",
    ".tmp/*",
    "build/*",
    "node_modules/*"
  ),

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/migration/mainline_migration_plan.json",

  [Parameter(Mandatory = $false)]
  [switch]$Apply,

  [Parameter(Mandatory = $false)]
  [switch]$BackupOnReplace
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path) {
  return [System.IO.Path]::GetFullPath($path)
}

function Resolve-RelativePath([string]$basePath, [string]$targetPath) {
  $baseAbs = Resolve-AbsolutePath $basePath
  $targetAbs = Resolve-AbsolutePath $targetPath
  $baseUri = New-Object System.Uri(($baseAbs.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar))
  $targetUri = New-Object System.Uri($targetAbs)
  $relUri = $baseUri.MakeRelativeUri($targetUri)
  return [System.Uri]::UnescapeDataString($relUri.ToString()).Replace('\', '/')
}

function Is-ExcludedPath([string]$relativePath, [string[]]$patterns) {
  foreach ($pattern in $patterns) {
    if ($relativePath -like $pattern) {
      return $true
    }
  }
  return $false
}

function Collect-SourceFiles([string]$rewriteRootAbs, [string[]]$includePaths, [string[]]$excludePatterns) {
  $all = @()
  foreach ($includePath in $includePaths) {
    $candidate = Join-Path $rewriteRootAbs $includePath
    if (-not (Test-Path $candidate)) {
      continue
    }

    $item = Get-Item $candidate
    if ($item.PSIsContainer) {
      $files = Get-ChildItem -Path $candidate -File -Recurse
      foreach ($file in $files) {
        $rel = Resolve-RelativePath $rewriteRootAbs $file.FullName
        if (Is-ExcludedPath $rel $excludePatterns) {
          continue
        }
        $all += [pscustomobject]@{
          relative_path = $rel
          full_path = $file.FullName
        }
      }
    } else {
      $relSingle = Resolve-RelativePath $rewriteRootAbs $item.FullName
      if (-not (Is-ExcludedPath $relSingle $excludePatterns)) {
        $all += [pscustomobject]@{
          relative_path = $relSingle
          full_path = $item.FullName
        }
      }
    }
  }

  $dedup = @{}
  foreach ($entry in $all) {
    $dedup[[string]$entry.relative_path] = [string]$entry.full_path
  }

  $result = @()
  foreach ($key in ($dedup.Keys | Sort-Object)) {
    $result += [pscustomobject]@{
      relative_path = $key
      full_path = $dedup[$key]
    }
  }
  return $result
}

function Compute-FileHashOrEmpty([string]$path) {
  if (-not (Test-Path $path)) {
    return ""
  }
  return [string](Get-FileHash -Algorithm SHA256 -Path $path).Hash
}

$rewriteRootAbs = Resolve-AbsolutePath $RewriteRoot
$mainlineRootAbs = Resolve-AbsolutePath $MainlineRoot

if (-not (Test-Path $rewriteRootAbs)) {
  throw "RewriteRoot not found: $rewriteRootAbs"
}
if (-not (Test-Path $mainlineRootAbs)) {
  throw "MainlineRoot not found: $mainlineRootAbs"
}

$sourceFiles = @(Collect-SourceFiles $rewriteRootAbs $IncludePaths $ExcludePatterns)
$operations = @()
$createCount = [int64]0
$replaceCount = [int64]0
$skipCount = [int64]0
$copyCount = [int64]0
$backupCount = [int64]0
$runTag = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")

for ($i = 0; $i -lt $sourceFiles.Count; $i++) {
  $source = $sourceFiles[$i]
  $targetPath = Join-Path $mainlineRootAbs $source.relative_path.Replace('/', '\')
  $sourceHash = Compute-FileHashOrEmpty $source.full_path
  $targetHash = Compute-FileHashOrEmpty $targetPath

  $action = "create"
  if (Test-Path $targetPath) {
    if ($sourceHash -eq $targetHash) {
      $action = "skip"
      $skipCount++
    } else {
      $action = "replace"
      $replaceCount++
    }
  } else {
    $createCount++
  }

  $applied = $false
  $backupPath = ""

  if ($Apply -and ($action -eq "create" -or $action -eq "replace")) {
    $targetDir = Split-Path -Parent $targetPath
    if ($targetDir -and -not (Test-Path $targetDir)) {
      New-Item -ItemType Directory -Path $targetDir | Out-Null
    }

    if ($action -eq "replace" -and $BackupOnReplace -and (Test-Path $targetPath)) {
      $backupPath = "$targetPath.bak.$runTag.$i"
      Copy-Item -Path $targetPath -Destination $backupPath -Force
      $backupCount++
    }

    Copy-Item -Path $source.full_path -Destination $targetPath -Force
    $applied = $true
    $copyCount++
  }

  $operations += [pscustomobject]@{
    relative_path = [string]$source.relative_path
    source_path = [string]$source.full_path
    target_path = [string]$targetPath
    action = [string]$action
    source_sha256 = [string]$sourceHash
    target_sha256 = [string]$targetHash
    applied = [bool]$applied
    backup_path = [string]$backupPath
  }
}

$report = [pscustomobject]@{
  schema_version = 1
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  mode = if ($Apply) { "apply" } else { "dry_run" }
  rewrite_root = $rewriteRootAbs
  mainline_root = $mainlineRootAbs
  include_paths = $IncludePaths
  exclude_patterns = $ExcludePatterns
  summary = [pscustomobject]@{
    total_files = [int64]$sourceFiles.Count
    create_count = $createCount
    replace_count = $replaceCount
    skip_count = $skipCount
    copied_count = $copyCount
    backup_count = $backupCount
  }
  operations = $operations
}

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
  New-Item -ItemType Directory -Path $outputDir | Out-Null
}
$report | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $OutputPath

if ($Apply) {
  Write-Output "PASS apply mainline migration plan"
} else {
  Write-Output "PASS build mainline migration plan"
}
Write-Output "report=$OutputPath"
