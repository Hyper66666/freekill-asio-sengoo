param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_dependency_audit.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

if (-not (Test-Path $BinaryPath)) {
  throw "native runtime binary not found: $BinaryPath"
}

$resolvedBinaryPath = (Resolve-Path $BinaryPath).Path
$deps = @()
$tool = ""
$warning = ""

$dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
if ($null -ne $dumpbin) {
  $tool = "dumpbin"
  $raw = & $dumpbin.Path /dependents $resolvedBinaryPath 2>$null
  foreach ($line in $raw) {
    $trim = [string]$line
    $trim = $trim.Trim()
    if ($trim -match "^[A-Za-z0-9._-]+\.dll$") {
      $deps += $trim
    }
  }
} else {
  $tool = "none"
  $warning = "dumpbin.exe unavailable; dependency list not collected"
}

$pythonDeps = @()
foreach ($dep in $deps) {
  if ($dep.ToLowerInvariant().Contains("python")) {
    $pythonDeps += $dep
  }
}

$hasPythonDependency = $pythonDeps.Count -gt 0
$pass = (-not $hasPythonDependency)

$report = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = $pass
  binary_path = $resolvedBinaryPath
  dependency_tool = $tool
  warning = $warning
  dependencies = $deps
  python_dependencies = $pythonDeps
}

Ensure-ParentDir $OutputPath
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("DEPENDENCY_AUDIT_OK={0}" -f $pass)
Write-Output ("DEPENDENCY_AUDIT_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $pass) {
  exit 1
}
