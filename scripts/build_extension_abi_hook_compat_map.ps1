param(
  [Parameter(Mandatory = $false)]
  [string]$InventoryPath = ".tmp/runtime_host/abi_hooks_inventory.json",

  [Parameter(Mandatory = $false)]
  [string]$RewriteRoot = "..",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/abi_hooks_compatibility_map.json",

  [Parameter(Mandatory = $false)]
  [string]$MarkdownOutputPath = ".tmp/runtime_host/ABI_HOOK_COMPATIBILITY.md"
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

function Parse-ValidCommands([string]$packageManagerScriptPath) {
  $content = Get-Content -Raw -Path $packageManagerScriptPath
  $m = [regex]::Match($content, 'ValidateSet\(([^)]*)\)')
  if (-not $m.Success) {
    return @()
  }
  $raw = [string]$m.Groups[1].Value
  $matches = [regex]::Matches($raw, '"([^"]+)"')
  $commands = @()
  foreach ($item in $matches) {
    $commands += [string]$item.Groups[1].Value
  }
  return @($commands | Sort-Object -Unique)
}

function Contains-Token([string]$path, [string]$token) {
  if (-not (Test-Path $path)) {
    return $false
  }
  $raw = Get-Content -Raw -Path $path
  return $raw.Contains($token)
}

function Add-CompatItem(
  [System.Collections.Generic.List[object]]$items,
  [string]$category,
  [string]$legacyName,
  [string]$legacySignature,
  [string]$rewriteTarget,
  [string]$status,
  [string]$notes
) {
  $items.Add([ordered]@{
    category = $category
    legacy_name = $legacyName
    legacy_signature = $legacySignature
    rewrite_target = $rewriteTarget
    status = $status
    notes = $notes
  })
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path $RewriteRoot -baseDir $scriptDir
$resolvedInventoryPath = Resolve-AbsolutePath -path $InventoryPath -baseDir $repoRoot
if (-not (Test-Path $resolvedInventoryPath)) {
  throw "missing inventory json: $resolvedInventoryPath"
}

$inventory = Get-Content -Raw -Path $resolvedInventoryPath | ConvertFrom-Json
$compatItems = New-Object "System.Collections.Generic.List[object]"

$packageManagerScriptPath = Resolve-AbsolutePath -path "scripts/package_manager_native.ps1" -baseDir $repoRoot
$packageCommandsAvailable = Parse-ValidCommands $packageManagerScriptPath

$packageCommandAliases = @{
  "u" = "upgrade"
}

foreach ($cmd in @($inventory.categories.package_commands)) {
  $legacyName = [string]$cmd.command
  $effective = if ($packageCommandAliases.ContainsKey($legacyName)) {
    [string]$packageCommandAliases[$legacyName]
  } else {
    $legacyName
  }
  $supported = $packageCommandsAvailable -contains $effective
  Add-CompatItem `
    -items $compatItems `
    -category "package_command" `
    -legacyName $legacyName `
    -legacySignature ([string]$cmd.handler) `
    -rewriteTarget "scripts/package_manager_native.ps1" `
    -status $(if ($supported) { "compatible" } else { "missing" }) `
    -notes $(if ($supported) { ("mapped to command '{0}'" -f $effective) } else { "command missing in native package manager" })
}

$packmanTargetPath = Resolve-AbsolutePath -path "src/codec_sg/packman.sg" -baseDir $repoRoot
$packmanMethodMap = @{
  "enablePack" = "apply_packman_enable"
  "disablePack" = "apply_packman_disable"
  "installPack" = "apply_packman_install"
  "upgradePack" = "apply_packman_upgrade"
  "removePack" = "apply_packman_remove"
  "syncToDatabase" = "apply_packman_syncpkgs"
  "syncFromDatabase" = "apply_packman_syncpkgs"
  "getPackHashes" = "apply_packman_pkgs"
  "getDisabledPacks" = "apply_packman_pkgs"
  "syncCommitHashToDatabase" = "apply_packman_sync_commit_hash_to_database"
  "updatePack" = "apply_packman_update_pack"
  "listPackages" = "apply_packman_list_packages"
  "forceCheckoutMaster" = "apply_packman_force_checkout_master"
  "refreshSummary" = "apply_packman_refresh_summary"
  "loadSummary" = "apply_packman_load_summary"
  "destroy" = "apply_packman_destroy"
  "downloadNewPack" = "apply_packman_download_new_pack"
}

foreach ($m in @($inventory.categories.packman_public_api)) {
  $legacyMethod = [string]$m.method
  if ($legacyMethod -eq "instance" -or $legacyMethod -eq "PackMan" -or $legacyMethod -eq "~PackMan") {
    continue
  }
  $rewriteFn = ""
  if ($packmanMethodMap.ContainsKey($legacyMethod)) {
    $rewriteFn = [string]$packmanMethodMap[$legacyMethod]
  }
  if ([string]::IsNullOrWhiteSpace($rewriteFn)) {
    Add-CompatItem $compatItems "packman_api" $legacyMethod ([string]$m.signature) "" "missing" "no mapped Sengoo transition function"
    continue
  }
  $present = Contains-Token $packmanTargetPath ("def " + $rewriteFn + "(")
  Add-CompatItem `
    -items $compatItems `
    -category "packman_api" `
    -legacyName $legacyMethod `
    -legacySignature ([string]$m.signature) `
    -rewriteTarget ("src/codec_sg/packman.sg::{0}" -f $rewriteFn) `
    -status $(if ($present) { "compatible" } else { "missing" }) `
    -notes $(if ($present) { "mapped to Sengoo packman contract/runtime function" } else { "mapped function not found in packman.sg" })
}

$rpcDispatchersSgPath = Resolve-AbsolutePath -path "src/server_sg/rpc_dispatchers.sg" -baseDir $repoRoot
$rpcDispatchersRaw = Get-Content -Raw -Path $rpcDispatchersSgPath
$catalogMatch = [regex]::Match($rpcDispatchersRaw, 'def\s+rpc_server_method_catalog_size\(\)\s*->\s*i64[\s\S]*?ensures\s+result\s*==\s*(\d+)')
$catalogSize = if ($catalogMatch.Success) { [int]$catalogMatch.Groups[1].Value } else { 0 }
$legacyRpcCount = @($inventory.categories.rpc_dispatch_methods).Count
$rpcCatalogStatus = if ($catalogSize -gt 0 -and $catalogSize -eq $legacyRpcCount) {
  "compatible"
} elseif ($catalogSize -gt 0) {
  "partial"
} else {
  "missing"
}
Add-CompatItem `
  -items $compatItems `
  -category "rpc_catalog" `
  -legacyName "rpc_method_catalog_size" `
  -legacySignature ("legacy_count={0}" -f $legacyRpcCount) `
  -rewriteTarget "src/server_sg/rpc_dispatchers.sg::rpc_server_method_catalog_size" `
  -status $rpcCatalogStatus `
  -notes ("legacy={0}, sengoo_catalog={1}" -f $legacyRpcCount, $catalogSize)

$luaBridgePath = Resolve-AbsolutePath -path "src/ffi_bridge_sg/rpc_bridge.sg" -baseDir $repoRoot
$luaFfiPath = Resolve-AbsolutePath -path "src/ffi_bridge_sg/lua_ffi.sg" -baseDir $repoRoot
$lifecycleScriptPath = Resolve-AbsolutePath -path "scripts/lua_extension_lifecycle_native.ps1" -baseDir $repoRoot

$rpcLuaMethodMap = @{
  "wait" = "apply_lua_bridge_response"
  "call" = "apply_lua_bridge_hello_notification"
  "alive" = "can_lua_bridge_dispatch"
  "getConnectionInfo" = "apply_lua_bridge_open"
}

foreach ($m in @($inventory.categories.rpc_lua_public_api)) {
  $legacyMethod = [string]$m.method
  if ($legacyMethod -eq "RpcLua" -or $legacyMethod -eq "~RpcLua") {
    $ctorToken = if ($legacyMethod -eq "RpcLua") { "ABI_HOOK_RPC_LUA_CTOR" } else { "ABI_HOOK_RPC_LUA_DTOR" }
    $exists = (Test-Path $lifecycleScriptPath) -and (Contains-Token $lifecycleScriptPath $ctorToken)
    Add-CompatItem `
      -items $compatItems `
      -category "rpc_lua_api" `
      -legacyName $legacyMethod `
      -legacySignature ([string]$m.signature) `
      -rewriteTarget ("scripts/lua_extension_lifecycle_native.ps1::{0}" -f $ctorToken) `
      -status $(if ($exists) { "compatible" } else { "missing" }) `
      -notes $(if ($exists) { "constructor/destructor lifecycle token present" } else { "constructor/destructor lifecycle token missing" })
    continue
  }
  $rewriteFn = ""
  if ($rpcLuaMethodMap.ContainsKey($legacyMethod)) {
    $rewriteFn = [string]$rpcLuaMethodMap[$legacyMethod]
  }
  if ([string]::IsNullOrWhiteSpace($rewriteFn)) {
    Add-CompatItem $compatItems "rpc_lua_api" $legacyMethod ([string]$m.signature) "" "missing" "no mapped Sengoo bridge function"
    continue
  }
  $present = (Contains-Token $luaBridgePath ("def " + $rewriteFn + "(")) -or (Contains-Token $luaFfiPath ("def " + $rewriteFn + "("))
  Add-CompatItem `
    -items $compatItems `
    -category "rpc_lua_api" `
    -legacyName $legacyMethod `
    -legacySignature ([string]$m.signature) `
    -rewriteTarget $rewriteFn `
    -status $(if ($present) { "compatible" } else { "missing" }) `
    -notes $(if ($present) { "mapped bridge function present in Sengoo runtime contracts" } else { "bridge function missing" })
}

$hookToSignal = @{
  "lua_process_spawn" = [ordered]@{
    path = "scripts/lua_extension_lifecycle_native.ps1"
    token = "ABI_HOOK_LUA_PROCESS_SPAWN"
  }
  "lua_entry_chdir" = [ordered]@{
    path = "scripts/lua_extension_lifecycle_native.ps1"
    token = "ABI_HOOK_LUA_ENTRY_CHDIR"
  }
  "lua_disabled_packs_env" = [ordered]@{
    path = "scripts/package_manager_native.ps1"
    token = "Sync-DisabledPacksSnapshot"
  }
  "lua_wait_loop" = [ordered]@{
    path = "src/ffi_bridge_sg/rpc_bridge.sg"
    token = "def apply_lua_bridge_response("
  }
  "lua_call_bridge" = [ordered]@{
    path = "src/ffi_bridge_sg/rpc_bridge.sg"
    token = "def apply_lua_bridge_hello_notification("
  }
  "lua_alive_probe" = [ordered]@{
    path = "src/ffi_bridge_sg/rpc_bridge.sg"
    token = "def can_lua_bridge_dispatch("
  }
  "lua_destructor_cleanup" = [ordered]@{
    path = "scripts/lua_extension_lifecycle_native.ps1"
    token = "ABI_HOOK_LUA_DESTRUCTOR_CLEANUP"
  }
}

foreach ($hook in @($inventory.categories.lua_lifecycle_hooks)) {
  $name = [string]$hook.hook
  $signal = if ($hookToSignal.ContainsKey($name)) { $hookToSignal[$name] } else { $null }
  $target = if ($null -eq $signal) { "" } else { [string]$signal.path }
  $token = if ($null -eq $signal) { "" } else { [string]$signal.token }
  $targetPath = if ([string]::IsNullOrWhiteSpace($target)) {
    ""
  } else {
    Resolve-AbsolutePath -path $target -baseDir $repoRoot
  }
  $tokenMatched = if ([string]::IsNullOrWhiteSpace($targetPath) -or [string]::IsNullOrWhiteSpace($token)) {
    $false
  } else {
    (Test-Path $targetPath) -and (Contains-Token $targetPath $token)
  }
  $status = if ($tokenMatched) { "compatible" } else { "missing" }
  Add-CompatItem `
    -items $compatItems `
    -category "lua_lifecycle_hook" `
    -legacyName $name `
    -legacySignature ("legacy_found={0}" -f ([bool]$hook.found)) `
    -rewriteTarget $(if ([string]::IsNullOrWhiteSpace($target)) { "" } else { ("{0}::{1}" -f $target, $token) }) `
    -status $status `
    -notes $(if ($status -eq "compatible") { "rewrite-side signal token matched" } else { "rewrite-side signal token missing" })
}

$sortedCompatItems = @($compatItems | Sort-Object -Property category, legacy_name)
$compatibleCount = @($sortedCompatItems | Where-Object { [string]$_.status -eq "compatible" }).Count
$partialCount = @($sortedCompatItems | Where-Object { [string]$_.status -eq "partial" }).Count
$missingCount = @($sortedCompatItems | Where-Object { [string]$_.status -eq "missing" }).Count
$totalCount = $sortedCompatItems.Count

$summaryByCategory = @{}
foreach ($item in $sortedCompatItems) {
  $cat = [string]$item.category
  if (-not $summaryByCategory.ContainsKey($cat)) {
    $summaryByCategory[$cat] = [ordered]@{
      total = 0
      compatible = 0
      partial = 0
      missing = 0
    }
  }
  $summaryByCategory[$cat].total++
  if ([string]$item.status -eq "compatible") {
    $summaryByCategory[$cat].compatible++
  } elseif ([string]$item.status -eq "partial") {
    $summaryByCategory[$cat].partial++
  } else {
    $summaryByCategory[$cat].missing++
  }
}

$map = [ordered]@{
  schema_version = 1
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  inventory_path = $resolvedInventoryPath
  rewrite_root = $repoRoot
  summary = [ordered]@{
    total = $totalCount
    compatible = $compatibleCount
    partial = $partialCount
    missing = $missingCount
    compatibility_ratio = if ($totalCount -eq 0) { 1.0 } else { [math]::Round(([double]$compatibleCount / [double]$totalCount), 6) }
  }
  summary_by_category = $summaryByCategory
  compatibility = $sortedCompatItems
}

Ensure-ParentDir $OutputPath
$map | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

$md = New-Object "System.Collections.Generic.List[string]"
$md.Add("# ABI/Hook Compatibility Map")
$md.Add("")
$md.Add(("Generated at: {0}" -f $map.generated_at_utc))
$md.Add("")
$md.Add("## Summary")
$md.Add("")
$md.Add(("- Total: {0}" -f $map.summary.total))
$md.Add(("- Compatible: {0}" -f $map.summary.compatible))
$md.Add(("- Partial: {0}" -f $map.summary.partial))
$md.Add(("- Missing: {0}" -f $map.summary.missing))
$md.Add(("- Compatibility ratio: {0}" -f $map.summary.compatibility_ratio))
$md.Add("")
$md.Add("## Items")
$md.Add("")
$md.Add("| category | legacy | status | rewrite target | notes |")
$md.Add("|---|---|---|---|---|")
foreach ($item in $sortedCompatItems) {
  $md.Add(("| `{0}` | `{1}` | `{2}` | `{3}` | {4} |" -f $item.category, $item.legacy_name, $item.status, $item.rewrite_target, $item.notes))
}

Ensure-ParentDir $MarkdownOutputPath
$md -join "`r`n" | Set-Content -Path $MarkdownOutputPath -Encoding UTF8

Write-Output "ABI_HOOK_COMPAT_MAP_OK=True"
Write-Output ("ABI_HOOK_COMPAT_MAP_JSON={0}" -f (Resolve-Path $OutputPath).Path)
Write-Output ("ABI_HOOK_COMPAT_MAP_MD={0}" -f (Resolve-Path $MarkdownOutputPath).Path)
