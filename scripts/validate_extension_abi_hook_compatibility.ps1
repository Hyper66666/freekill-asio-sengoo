param(
  [Parameter(Mandatory = $false)]
  [string]$InventoryScriptPath = "scripts/build_extension_abi_hook_inventory.ps1",

  [Parameter(Mandatory = $false)]
  [string]$CompatMapScriptPath = "scripts/build_extension_abi_hook_compat_map.ps1",

  [Parameter(Mandatory = $false)]
  [string]$InventoryPath = ".tmp/runtime_host/abi_hooks_inventory.json",

  [Parameter(Mandatory = $false)]
  [string]$CompatMapPath = ".tmp/runtime_host/abi_hooks_compatibility_map.json",

  [Parameter(Mandatory = $false)]
  [string[]]$RequiredCategories = @(
    "package_command",
    "packman_api",
    "rpc_catalog",
    "rpc_lua_api",
    "lua_lifecycle_hook"
  ),

  [Parameter(Mandatory = $false)]
  [switch]$AllowPartial,

  [Parameter(Mandatory = $false)]
  [switch]$Enforce,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/abi_hook_validation_report.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

if (-not (Test-Path $InventoryScriptPath)) {
  throw "inventory script not found: $InventoryScriptPath"
}
if (-not (Test-Path $CompatMapScriptPath)) {
  throw "compat map script not found: $CompatMapScriptPath"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $InventoryScriptPath -OutputPath $InventoryPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "failed to build abi/hook inventory"
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $CompatMapScriptPath -InventoryPath $InventoryPath -OutputPath $CompatMapPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "failed to build abi/hook compat map"
}

if (-not (Test-Path $CompatMapPath)) {
  throw "compat map json missing: $CompatMapPath"
}

$map = Get-Content -Raw -Path $CompatMapPath | ConvertFrom-Json
$compatItems = @($map.compatibility)
$scope = @($compatItems | Where-Object { $RequiredCategories -contains [string]$_.category })

$allowPartialFlag = [bool]$AllowPartial
$enforceFlag = [bool]$Enforce
$blockedStatuses = if ($allowPartialFlag) { @("missing") } else { @("missing", "partial") }
$blockers = @($scope | Where-Object { $blockedStatuses -contains [string]$_.status })
$pass = ($blockers.Count -eq 0)

$report = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  enforce = $enforceFlag
  allow_partial = $allowPartialFlag
  required_categories = $RequiredCategories
  pass = $pass
  summary = [ordered]@{
    scoped_total = $scope.Count
    blocker_count = $blockers.Count
    blocked_statuses = $blockedStatuses
  }
  blocker_items = $blockers
  compat_map_path = (Resolve-Path $CompatMapPath).Path
  compat_summary = $map.summary
}

Ensure-ParentDir $OutputPath
$report | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("ABI_HOOK_VALIDATION_PASS={0}" -f $pass)
Write-Output ("ABI_HOOK_VALIDATION_ENFORCE={0}" -f $enforceFlag)
Write-Output ("ABI_HOOK_VALIDATION_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if ($enforceFlag -and -not $pass) {
  exit 1
}
