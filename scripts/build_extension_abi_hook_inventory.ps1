param(
  [Parameter(Mandatory = $false)]
  [string]$LegacyRoot = "..",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/abi_hooks_inventory.json",

  [Parameter(Mandatory = $false)]
  [string]$MarkdownOutputPath = ".tmp/runtime_host/ABI_HOOKS_INVENTORY.md"
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

function Read-Lines([string]$path) {
  if (-not (Test-Path $path)) {
    throw "missing source file: $path"
  }
  return Get-Content -Path $path
}

function Build-RpcDispatchInventory([string]$path) {
  $lines = Read-Lines $path
  $handlers = @{}
  $bindings = @()
  for ($idx = 0; $idx -lt $lines.Count; $idx++) {
    $line = [string]$lines[$idx]
    $def = [regex]::Match($line, '^\s*static\s+_rpcRet\s+(_rpc_[A-Za-z0-9_]+)\s*\(([^)]*)\)')
    if ($def.Success) {
      $name = [string]$def.Groups[1].Value
      $signature = [string]$def.Groups[2].Value.Trim()
      $handlers[$name] = [ordered]@{
        handler = $name
        signature = $signature
        line = $idx + 1
      }
      continue
    }

    $bind = [regex]::Match($line, '\{\s*"([^"]+)"\s*,\s*(_rpc_[A-Za-z0-9_]+)\s*\}')
    if ($bind.Success) {
      $method = [string]$bind.Groups[1].Value
      $handler = [string]$bind.Groups[2].Value
      if ($method.Length -gt 0) {
        $handlerMeta = $null
        if ($handlers.ContainsKey($handler)) {
          $handlerMeta = $handlers[$handler]
        }
        $bindings += [pscustomobject][ordered]@{
          method = $method
          handler = $handler
          handler_signature = if ($null -ne $handlerMeta) { [string]$handlerMeta.signature } else { "" }
          handler_line = if ($null -ne $handlerMeta) { [int]$handlerMeta.line } else { 0 }
          map_line = $idx + 1
        }
      }
    }
  }
  return @($bindings | Sort-Object -Property method)
}

function Build-ShellCommandInventory([string]$path) {
  $lines = Read-Lines $path
  $commands = @()
  for ($idx = 0; $idx -lt $lines.Count; $idx++) {
    $line = [string]$lines[$idx]
    $m = [regex]::Match($line, '\{\s*"([^"]+)"\s*,\s*&Shell::([A-Za-z0-9_]+)\s*\}')
    if ($m.Success) {
      $commands += [pscustomobject][ordered]@{
        command = [string]$m.Groups[1].Value
        handler = [string]$m.Groups[2].Value
        line = $idx + 1
      }
    }
  }
  return @($commands | Sort-Object -Property command)
}

function Build-PublicMethodInventory([string]$path, [string]$className) {
  $lines = Read-Lines $path
  $methods = @()
  $inClass = $false
  $publicDepth = 0
  for ($idx = 0; $idx -lt $lines.Count; $idx++) {
    $line = [string]$lines[$idx]
    if (-not $inClass) {
      if ($line -match ("class\s+{0}\b" -f [regex]::Escape($className))) {
        $inClass = $true
      }
      continue
    }
    if ($line -match '^\s*public:\s*$') {
      $publicDepth = 1
      continue
    }
    if ($line -match '^\s*(private|protected):\s*$') {
      $publicDepth = 0
      continue
    }
    if ($publicDepth -ne 1) {
      continue
    }

    $sig = [regex]::Match($line, '^\s*(?:explicit\s+)?([~A-Za-z_][A-Za-z0-9_:<>\*&\s]*)\s+([A-Za-z_~][A-Za-z0-9_]*)\s*\(([^;]*)\)\s*(?:const)?\s*;')
    if ($sig.Success) {
      $returnType = [string]$sig.Groups[1].Value.Trim()
      $methodName = [string]$sig.Groups[2].Value.Trim()
      $params = [string]$sig.Groups[3].Value.Trim()
      $methods += [pscustomobject][ordered]@{
        method = $methodName
        return_type = $returnType
        params = $params
        signature = ("{0} {1}({2})" -f $returnType, $methodName, $params).Trim()
        line = $idx + 1
      }
      continue
    }

    $ctor = [regex]::Match($line, ('^\s*(?:explicit\s+)?({0}|~{0})\s*\(([^;]*)\)\s*;' -f [regex]::Escape($className)))
    if ($ctor.Success) {
      $methodName = [string]$ctor.Groups[1].Value.Trim()
      $params = [string]$ctor.Groups[2].Value.Trim()
      $methods += [pscustomobject][ordered]@{
        method = $methodName
        return_type = ""
        params = $params
        signature = ("{0}({1})" -f $methodName, $params).Trim()
        line = $idx + 1
      }
    }
  }
  return @($methods | Sort-Object -Property method, line -Unique)
}

function Build-LuaLifecycleHookInventory([string]$path) {
  $lines = Read-Lines $path
  $hooks = @()
  $patterns = @(
    @{ name = "lua_process_spawn"; regex = 'execlp\("lua5\.4"'; detail = "spawn lua5.4 process for rpc entry" },
    @{ name = "lua_entry_chdir"; regex = 'chdir\("packages/freekill-core"\)'; detail = "switch cwd into freekill-core package" },
    @{ name = "lua_disabled_packs_env"; regex = 'FK_DISABLED_PACKAGES'; detail = "inject disabled packages into lua env" },
    @{ name = "lua_wait_loop"; regex = 'RpcLua::wait\s*\('; detail = "wait for lua rpc response/notification" },
    @{ name = "lua_call_bridge"; regex = 'RpcLua::call\s*\('; detail = "c++ to lua rpc dispatch" },
    @{ name = "lua_alive_probe"; regex = 'RpcLua::alive\s*\('; detail = "lua process health probe" },
    @{ name = "lua_destructor_cleanup"; regex = 'RpcLua::~RpcLua'; detail = "lua process cleanup on destroy" }
  )

  foreach ($pattern in $patterns) {
    $matchedLine = 0
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
      if ([regex]::IsMatch([string]$lines[$idx], [string]$pattern.regex)) {
        $matchedLine = $idx + 1
        break
      }
    }
    $hooks += [pscustomobject][ordered]@{
      hook = [string]$pattern.name
      found = ($matchedLine -gt 0)
      line = $matchedLine
      detail = [string]$pattern.detail
    }
  }
  return $hooks
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$legacyRootAbs = Resolve-AbsolutePath -path $LegacyRoot -baseDir $repoRoot

$rpcDispatchersPath = Join-Path $legacyRootAbs "src/server/gamelogic/rpc-dispatchers.cpp"
$shellPath = Join-Path $legacyRootAbs "src/server/admin/shell.cpp"
$packmanHeaderPath = Join-Path $legacyRootAbs "src/core/packman.h"
$rpcLuaHeaderPath = Join-Path $legacyRootAbs "src/server/rpc-lua/rpc-lua.h"
$rpcLuaSourcePath = Join-Path $legacyRootAbs "src/server/rpc-lua/rpc-lua.cpp"

$rpcMethods = Build-RpcDispatchInventory $rpcDispatchersPath
$shellCommands = Build-ShellCommandInventory $shellPath
$packmanMethods = Build-PublicMethodInventory $packmanHeaderPath "PackMan"
$rpcLuaMethods = Build-PublicMethodInventory $rpcLuaHeaderPath "RpcLua"
$luaHooks = Build-LuaLifecycleHookInventory $rpcLuaSourcePath

$packageCommandNames = @("install", "remove", "pkgs", "syncpkgs", "enable", "disable", "upgrade", "u")
$packageCommands = @($shellCommands | Where-Object { $packageCommandNames -contains [string]$_.command } | Sort-Object -Property command)

$inventory = [ordered]@{
  schema_version = 1
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  legacy_root = $legacyRootAbs
  sources = [ordered]@{
    rpc_dispatchers = $rpcDispatchersPath
    admin_shell = $shellPath
    packman_header = $packmanHeaderPath
    rpc_lua_header = $rpcLuaHeaderPath
    rpc_lua_source = $rpcLuaSourcePath
  }
  summary = [ordered]@{
    rpc_method_count = $rpcMethods.Count
    shell_command_count = $shellCommands.Count
    package_command_count = $packageCommands.Count
    packman_method_count = $packmanMethods.Count
    rpc_lua_method_count = $rpcLuaMethods.Count
    lua_hook_count = $luaHooks.Count
    lua_hook_found_count = @($luaHooks | Where-Object { [bool]$_.found }).Count
  }
  categories = [ordered]@{
    rpc_dispatch_methods = $rpcMethods
    admin_shell_commands = $shellCommands
    package_commands = $packageCommands
    packman_public_api = $packmanMethods
    rpc_lua_public_api = $rpcLuaMethods
    lua_lifecycle_hooks = $luaHooks
  }
}

Ensure-ParentDir $OutputPath
$inventory | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

$md = New-Object "System.Collections.Generic.List[string]"
$md.Add("# ABI/Hook Inventory")
$md.Add("")
$md.Add(("Generated at: {0}" -f $inventory.generated_at_utc))
$md.Add(('Legacy root: `{0}`' -f $legacyRootAbs))
$md.Add("")
$md.Add("## Summary")
$md.Add("")
$md.Add(("- RPC methods: {0}" -f $inventory.summary.rpc_method_count))
$md.Add(("- Shell commands: {0}" -f $inventory.summary.shell_command_count))
$md.Add(("- Package commands: {0}" -f $inventory.summary.package_command_count))
$md.Add(("- PackMan public methods: {0}" -f $inventory.summary.packman_method_count))
$md.Add(("- RpcLua public methods: {0}" -f $inventory.summary.rpc_lua_method_count))
$md.Add(("- Lua lifecycle hooks found: {0}/{1}" -f $inventory.summary.lua_hook_found_count, $inventory.summary.lua_hook_count))
$md.Add("")
$md.Add("## Package Commands")
$md.Add("")
$md.Add("| command | handler | line |")
$md.Add("|---|---|---:|")
foreach ($item in $packageCommands) {
  $md.Add(('| `{0}` | `{1}` | {2} |' -f $item.command, $item.handler, $item.line))
}
$md.Add("")
$md.Add("## RPC Dispatch Methods")
$md.Add("")
$md.Add("| method | handler | map line |")
$md.Add("|---|---|---:|")
foreach ($item in $rpcMethods) {
  $md.Add(('| `{0}` | `{1}` | {2} |' -f $item.method, $item.handler, $item.map_line))
}
$md.Add("")
$md.Add("## Lua Lifecycle Hooks")
$md.Add("")
$md.Add("| hook | found | line | detail |")
$md.Add("|---|---|---:|---|")
foreach ($item in $luaHooks) {
  $md.Add(('| `{0}` | `{1}` | {2} | {3} |' -f $item.hook, $item.found, $item.line, $item.detail))
}

Ensure-ParentDir $MarkdownOutputPath
$md -join "`r`n" | Set-Content -Path $MarkdownOutputPath -Encoding UTF8

Write-Output "ABI_HOOK_INVENTORY_OK=True"
Write-Output ("ABI_HOOK_INVENTORY_JSON={0}" -f (Resolve-Path $OutputPath).Path)
Write-Output ("ABI_HOOK_INVENTORY_MD={0}" -f (Resolve-Path $MarkdownOutputPath).Path)
