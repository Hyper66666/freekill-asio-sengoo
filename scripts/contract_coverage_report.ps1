param(
  [Parameter(Mandatory = $false)]
  [string]$MapPath = "scripts/fixtures/migration_map.md",

  [Parameter(Mandatory = $false)]
  [string]$LegacyRoot = "..",

  [Parameter(Mandatory = $false)]
  [string]$OverridesPath = "scripts/fixtures/contract_coverage_overrides.json",

  [Parameter(Mandatory = $false)]
  [string]$JsonOutputPath = ".tmp/contract_coverage/contract_coverage_report.json",

  [Parameter(Mandatory = $false)]
  [string]$MarkdownOutputPath = ".tmp/contract_coverage/CONTRACT_COVERAGE.md"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Normalize-Name([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) {
    return ""
  }
  $lower = $text.ToLowerInvariant()
  return ($lower -replace '[^a-z0-9]', '')
}

function Read-Overrides([string]$path) {
  if (-not (Test-Path $path)) {
    return @{}
  }
  $raw = Get-Content -Raw $path
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{}
  }
  $parsed = $raw | ConvertFrom-Json
  $table = @{}
  foreach ($prop in $parsed.PSObject.Properties) {
    $arr = @()
    foreach ($fn in @($prop.Value.covered_cpp_functions)) {
      $arr += [string]$fn
    }
    $table[[string]$prop.Name] = $arr
  }
  return $table
}

function Get-CppFunctions([string]$path) {
  if (-not (Test-Path $path)) {
    throw "Missing C++ source: $path"
  }

  $lines = Get-Content $path
  $functions = @()
  $seen = @{}
  $skipNames = @(
    "if", "for", "while", "switch", "catch", "return", "sizeof"
  )

  foreach ($line in $lines) {
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("//")) {
      continue
    }

    $m1 = [regex]::Match($line, '^\s*(?:[\w:<>\~\*&\s]+)\s+([A-Za-z_]\w*)::(~?[A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const)?\s*\{')
    if ($m1.Success) {
      $name = "$($m1.Groups[1].Value)::$($m1.Groups[2].Value)"
      if (-not $seen.ContainsKey($name)) {
        $functions += $name
        $seen[$name] = $true
      }
      continue
    }

    $m2 = [regex]::Match($line, '^\s*([A-Za-z_]\w*)::(~?[A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const)?\s*\{')
    if ($m2.Success) {
      $name = "$($m2.Groups[1].Value)::$($m2.Groups[2].Value)"
      if (-not $seen.ContainsKey($name)) {
        $functions += $name
        $seen[$name] = $true
      }
      continue
    }

    $m3 = [regex]::Match($line, '^\s*(?:[\w:<>\~\*&\s]+)\s+([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const)?\s*\{')
    if ($m3.Success) {
      $fn = [string]$m3.Groups[1].Value
      if ($skipNames -contains $fn) {
        continue
      }
      if (-not $seen.ContainsKey($fn)) {
        $functions += $fn
        $seen[$fn] = $true
      }
    }
  }

  return $functions
}

function Get-SgFunctions([string]$path) {
  if (-not (Test-Path $path)) {
    throw "Missing Sengoo source: $path"
  }

  $lines = Get-Content $path
  $result = @()

  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $m = [regex]::Match($line, '^\s*def\s+([A-Za-z_]\w*)\s*\(')
    if (-not $m.Success) {
      continue
    }

    $name = [string]$m.Groups[1].Value
    $hasContract = $false
    $j = $i + 1
    while ($j -lt $lines.Count) {
      $nextLine = $lines[$j].Trim()
      if ($nextLine -match '^def\s+[A-Za-z_]\w*\s*\(') {
        break
      }
      if ($nextLine -match '^(requires|ensures)\b') {
        $hasContract = $true
      }
      if ($nextLine.Contains("{")) {
        break
      }
      $j++
    }

    $result += [pscustomobject]@{
      name = $name
      has_contract = $hasContract
    }
  }

  return $result
}

function Resolve-RelativeToRoot([string]$root, [string]$relPath) {
  $joined = Join-Path $root $relPath
  if (Test-Path $joined) {
    return (Resolve-Path $joined).Path
  }

  $trimmed = $relPath
  while ($trimmed.StartsWith("..\") -or $trimmed.StartsWith("../")) {
    $trimmed = $trimmed.Substring(3)
  }
  while ($trimmed.StartsWith(".\") -or $trimmed.StartsWith("./")) {
    $trimmed = $trimmed.Substring(2)
  }

  $fallback = Join-Path (Resolve-Path ".").Path $trimmed
  if (Test-Path $fallback) {
    return (Resolve-Path $fallback).Path
  }

  throw "Cannot resolve path '$relPath' from root '$root' (fallback '$fallback')"
}

if (-not (Test-Path $MapPath)) {
  $docsMapPath = "docs/MIGRATION_MAP.md"
  if (Test-Path $docsMapPath) {
    $MapPath = $docsMapPath
  } else {
    throw "Missing migration map: $MapPath"
  }
}

if (-not (Test-Path $OverridesPath)) {
  $docsOverridesPath = "docs/CONTRACT_COVERAGE_OVERRIDES.json"
  if (Test-Path $docsOverridesPath) {
    $OverridesPath = $docsOverridesPath
  }
}

$legacyRootAbs = (Resolve-Path $LegacyRoot).Path
$mapContent = Get-Content -Raw $MapPath
$mapMatches = [regex]::Matches($mapContent, '\| `([^`]+\.cpp)` \| `([^`]+\.sg)` \|')
if ($mapMatches.Count -eq 0) {
  throw "No migration pairs found in $MapPath"
}

$overrides = Read-Overrides $OverridesPath
$pairReports = @()
$totalCpp = [int64]0
$totalCovered = [int64]0
$totalSg = [int64]0
$totalSgContract = [int64]0
$totalAutoCovered = [int64]0
$totalOverrideCovered = [int64]0

foreach ($m in $mapMatches) {
  $cppRel = [string]$m.Groups[1].Value
  $sgRel = [string]$m.Groups[2].Value

  $cppAbs = Resolve-RelativeToRoot $legacyRootAbs $cppRel
  $sgAbs = (Resolve-Path $sgRel).Path

  $cppFns = @((Get-CppFunctions $cppAbs) | Sort-Object -Unique)
  $sgFns = @(Get-SgFunctions $sgAbs)
  $sgFnNames = @($sgFns | ForEach-Object { [string]$_.name })
  $sgFnNormSet = @{}
  foreach ($name in $sgFnNames) {
    $sgFnNormSet[(Normalize-Name $name)] = $true
  }

  $autoCovered = @()
  foreach ($cppFn in $cppFns) {
    $methodName = $cppFn
    if ($cppFn.Contains("::")) {
      $parts = $cppFn.Split("::")
      $methodName = $parts[$parts.Count - 1]
    }
    $norm = Normalize-Name $methodName
    if ($sgFnNormSet.ContainsKey($norm)) {
      $autoCovered += $cppFn
    }
  }
  $autoCovered = @($autoCovered | Sort-Object -Unique)

  $overrideCovered = @()
  if ($overrides.ContainsKey($cppRel)) {
    $explicit = @($overrides[$cppRel])
    foreach ($candidate in $explicit) {
      if ($cppFns -contains $candidate) {
        $overrideCovered += $candidate
      }
    }
  }
  $overrideCovered = @($overrideCovered | Sort-Object -Unique)

  $coveredSet = @{}
  foreach ($fn in $autoCovered) { $coveredSet[$fn] = $true }
  foreach ($fn in $overrideCovered) { $coveredSet[$fn] = $true }
  $coveredFns = @($coveredSet.Keys | Sort-Object)
  $uncoveredFns = @($cppFns | Where-Object { -not $coveredSet.ContainsKey($_) } | Sort-Object)

  $cppCount = [int64]$cppFns.Count
  $sgCount = [int64]$sgFns.Count
  $sgContractCount = [int64](@($sgFns | Where-Object { [bool]$_.has_contract }).Count)
  $coveredCount = [int64]$coveredFns.Count
  $autoCoveredCount = [int64]$autoCovered.Count
  $overrideCoveredCount = [int64]$overrideCovered.Count
  $coverageRatio = if ($cppCount -eq 0) { 1.0 } else { [double]$coveredCount / [double]$cppCount }

  $pairReports += [pscustomobject]@{
    cpp_source = $cppRel
    sg_target = $sgRel
    cpp_function_count = $cppCount
    sg_function_count = $sgCount
    sg_contract_function_count = $sgContractCount
    auto_covered_count = $autoCoveredCount
    override_covered_count = $overrideCoveredCount
    covered_count = $coveredCount
    uncovered_count = [int64]$uncoveredFns.Count
    coverage_ratio = [math]::Round($coverageRatio, 6)
    uncovered_cpp_functions = $uncoveredFns
  }

  $totalCpp += $cppCount
  $totalCovered += $coveredCount
  $totalSg += $sgCount
  $totalSgContract += $sgContractCount
  $totalAutoCovered += $autoCoveredCount
  $totalOverrideCovered += $overrideCoveredCount
}

$overallCoverageRatio = if ($totalCpp -eq 0) { 1.0 } else { [double]$totalCovered / [double]$totalCpp }

$report = [pscustomobject]@{
  schema_version = 1
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  map_path = (Resolve-Path $MapPath).Path
  overrides_path = if (Test-Path $OverridesPath) { (Resolve-Path $OverridesPath).Path } else { "" }
  summary = [pscustomobject]@{
    mapped_file_count = [int64]$pairReports.Count
    cpp_function_total = $totalCpp
    covered_cpp_function_total = $totalCovered
    uncovered_cpp_function_total = [int64]($totalCpp - $totalCovered)
    sg_function_total = $totalSg
    sg_contract_function_total = $totalSgContract
    auto_covered_total = $totalAutoCovered
    override_covered_total = $totalOverrideCovered
    coverage_ratio = [math]::Round($overallCoverageRatio, 6)
  }
  files = $pairReports
}

$jsonDir = Split-Path -Parent $JsonOutputPath
if ($jsonDir -and -not (Test-Path $jsonDir)) {
  New-Item -ItemType Directory -Path $jsonDir | Out-Null
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $JsonOutputPath

$mdLines = @()
$mdLines += "# Contract Coverage"
$mdLines += ""
$mdLines += "Generated at: $($report.generated_at_utc)"
$mdLines += ""
$mdLines += "## Summary"
$mdLines += ""
$mdLines += "- Mapped files: $($report.summary.mapped_file_count)"
$mdLines += "- C++ functions: $($report.summary.cpp_function_total)"
$mdLines += "- Covered C++ functions: $($report.summary.covered_cpp_function_total)"
$mdLines += "- Uncovered C++ functions: $($report.summary.uncovered_cpp_function_total)"
$mdLines += "- Sengoo functions: $($report.summary.sg_function_total)"
$mdLines += "- Sengoo functions with contracts: $($report.summary.sg_contract_function_total)"
$mdLines += "- Coverage ratio: $($report.summary.coverage_ratio)"
$mdLines += ""
$mdLines += "## File Breakdown"
$mdLines += ""
$mdLines += "| C++ Source | Sengoo Target | C++ Fn | Covered | Coverage | Sengoo Fn | Sengoo Contract Fn |"
$mdLines += "|---|---|---:|---:|---:|---:|---:|"
foreach ($file in $pairReports) {
  $mdLines += "| ``$($file.cpp_source)`` | ``$($file.sg_target)`` | $($file.cpp_function_count) | $($file.covered_count) | $($file.coverage_ratio) | $($file.sg_function_count) | $($file.sg_contract_function_count) |"
}
$mdLines += ""
$mdLines += "## Top Uncovered (By File)"
$mdLines += ""
foreach ($file in ($pairReports | Sort-Object uncovered_count -Descending | Select-Object -First 10)) {
  if ($file.uncovered_count -le 0) {
    continue
  }
  $mdLines += "### ``$($file.cpp_source)``"
  $mdLines += ""
  foreach ($fn in @($file.uncovered_cpp_functions | Select-Object -First 20)) {
    $mdLines += "- ``$fn``"
  }
  $mdLines += ""
}

$mdDir = Split-Path -Parent $MarkdownOutputPath
if ($mdDir -and -not (Test-Path $mdDir)) {
  New-Item -ItemType Directory -Path $mdDir | Out-Null
}
$mdLines -join "`r`n" | Set-Content -Encoding UTF8 $MarkdownOutputPath

Write-Output "PASS contract coverage report"
Write-Output "JSON: $JsonOutputPath"
Write-Output "Markdown: $MarkdownOutputPath"
