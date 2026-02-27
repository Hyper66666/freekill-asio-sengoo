param(
  [Parameter(Mandatory = $false)]
  [string]$LifecycleScriptPath = "scripts/lua_extension_lifecycle_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/lua_extension_lifecycle_smoke_native.json"
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

function Invoke-LifecycleCommand(
  [string]$scriptPath,
  [string]$packagesRoot,
  [string]$statePath,
  [string]$commandName,
  [string]$name,
  [string]$hook,
  [int]$expectedExitCode,
  [string]$reportPath
) {
  $args = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $scriptPath,
    "-Command",
    $commandName,
    "-PackagesRoot",
    $packagesRoot,
    "-StatePath",
    $statePath,
    "-OutputPath",
    $reportPath,
    "-AsJson"
  )
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    $args += @("-Name", $name)
  }
  if (-not [string]::IsNullOrWhiteSpace($hook)) {
    $args += @("-Hook", $hook)
  }
  $raw = & powershell @args
  $exitCode = [int]$LASTEXITCODE
  if ($exitCode -ne $expectedExitCode) {
    throw ("lifecycle command {0} expected exit {1}, actual {2}" -f $commandName, $expectedExitCode, $exitCode)
  }
  $jsonText = ($raw -join [Environment]::NewLine).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw ("lifecycle command {0} returned empty json output" -f $commandName)
  }
  return ($jsonText | ConvertFrom-Json)
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedLifecycleScriptPath = Resolve-AbsolutePath -path $LifecycleScriptPath -baseDir $repoRoot

if (-not (Test-Path $resolvedLifecycleScriptPath)) {
  throw "lifecycle script not found: $resolvedLifecycleScriptPath"
}

$tmpRoot = Resolve-AbsolutePath -path ".tmp/lua_lifecycle_smoke_native" -baseDir $repoRoot
if (Test-Path $tmpRoot) {
  Remove-Item -Recurse -Force $tmpRoot
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$packagesRoot = Join-Path $tmpRoot "packages"
$statePath = Join-Path $tmpRoot "lua_state.json"
$reportRoot = Join-Path $tmpRoot "reports"
New-Item -ItemType Directory -Path $packagesRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

$extName = "ext-lifecycle"
$entryPath = Join-Path $packagesRoot "$extName/lua/server/rpc/entry.lua"
New-Item -ItemType Directory -Path (Split-Path -Parent $entryPath) -Force | Out-Null
@"
local M = {}
function M.ping(payload)
  return "pong:" .. tostring(payload)
end
return M
"@ | Set-Content -Path $entryPath -Encoding UTF8

$results = [ordered]@{}
$results.discover = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "discover" "" "" 0 (Join-Path $reportRoot "01-discover.json")
$results.load = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "load" $extName "" 0 (Join-Path $reportRoot "02-load.json")
$results.call_loaded = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "call" $extName "ping" 0 (Join-Path $reportRoot "03-call-loaded.json")

Add-Content -Path $entryPath -Encoding UTF8 -Value "`n-- hot reload marker"
$results.hot_reload = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "hot_reload" $extName "" 0 (Join-Path $reportRoot "04-hot-reload.json")
$results.unload = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "unload" $extName "" 0 (Join-Path $reportRoot "05-unload.json")
$results.call_unloaded = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "call" $extName "ping" 1 (Join-Path $reportRoot "06-call-unloaded.json")
$results.status = Invoke-LifecycleCommand $resolvedLifecycleScriptPath $packagesRoot $statePath "status" "" "" 0 (Join-Path $reportRoot "07-status.json")

$checks = [ordered]@{
  discovered_extension = (@($results.discover.details.found_extensions) -contains $extName)
  load_ok = [bool]$results.load.ok
  call_ok = [bool]$results.call_loaded.ok
  hot_reload_ok = [bool]$results.hot_reload.ok
  unload_ok = [bool]$results.unload.ok
  unloaded_call_rejected = ([int]$results.call_unloaded.reason_code -eq 9504)
  loaded_count_zero_after_unload = ([int]$results.status.loaded_count -eq 0)
}
$pass = [bool]$checks.discovered_extension `
  -and [bool]$checks.load_ok `
  -and [bool]$checks.call_ok `
  -and [bool]$checks.hot_reload_ok `
  -and [bool]$checks.unload_ok `
  -and [bool]$checks.unloaded_call_rejected `
  -and [bool]$checks.loaded_count_zero_after_unload

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = $pass
  lifecycle_script = $resolvedLifecycleScriptPath
  packages_root = $packagesRoot
  state_path = $statePath
  checks = $checks
  command_reports = $results
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("LUA_LIFECYCLE_SMOKE_PASS={0}" -f $pass)
Write-Output ("LUA_LIFECYCLE_SMOKE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $pass) {
  exit 1
}
