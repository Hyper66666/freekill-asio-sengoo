param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("discover", "load", "call", "hot_reload", "unload", "status")]
  [string]$Command,

  [Parameter(Mandatory = $false)]
  [string]$Name = "",

  [Parameter(Mandatory = $false)]
  [string]$Hook = "ping",

  [Parameter(Mandatory = $false)]
  [string]$PayloadJson = "{}",

  [Parameter(Mandatory = $false)]
  [string]$PackagesRoot = "packages",

  [Parameter(Mandatory = $false)]
  [string]$StatePath = ".tmp/runtime_host/lua_extension_state.json",

  [Parameter(Mandatory = $false)]
  [string]$LuaExe = "lua5.4",

  [Parameter(Mandatory = $false)]
  [switch]$EnableLuaExecution,

  [Parameter(Mandatory = $false)]
  [switch]$ForceReload,

  [Parameter(Mandatory = $false)]
  [switch]$AsJson,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/lua_extension_lifecycle_last.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ABI_HOOK_RPC_LUA_CTOR
# ABI_HOOK_RPC_LUA_DTOR
# ABI_HOOK_LUA_PROCESS_SPAWN
# ABI_HOOK_LUA_ENTRY_CHDIR
# ABI_HOOK_LUA_DESTRUCTOR_CLEANUP

function Reason-Ok() { 0 }
function Reason-InvalidArgument() { 9501 }
function Reason-ExtensionMissing() { 9502 }
function Reason-StateMissing() { 9503 }
function Reason-ExtensionNotLoaded() { 9504 }
function Reason-LuaRuntimeUnavailable() { 9505 }
function Reason-LuaExecutionFailure() { 9506 }
function Reason-ReloadNotNeeded() { 9507 }
function Reason-UnknownFailure() { 9599 }

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

function Extension-EntryPath([string]$packagesRoot, [string]$name) {
  return (Join-Path (Join-Path $packagesRoot $name) "lua/server/rpc/entry.lua")
}

function Load-State([string]$statePath) {
  if (-not (Test-Path $statePath)) {
    return [ordered]@{
      schema_version = 1
      generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      extensions = @()
    }
  }
  $raw = Get-Content -Raw -Path $statePath
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [ordered]@{
      schema_version = 1
      generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      extensions = @()
    }
  }
  $parsed = $raw | ConvertFrom-Json
  $records = @()
  foreach ($ext in @($parsed.extensions)) {
    $records += [pscustomobject]@{
      name = [string]$ext.name
      path = [string]$ext.path
      entry = [string]$ext.entry
      loaded = [bool]$ext.loaded
      entry_hash = [string]$ext.entry_hash
      loaded_at_utc = [string]$ext.loaded_at_utc
      call_count = [int64]$ext.call_count
      reload_count = [int64]$ext.reload_count
      last_call_at_utc = [string]$ext.last_call_at_utc
      last_reload_at_utc = [string]$ext.last_reload_at_utc
      last_error = [string]$ext.last_error
      hooks = @($ext.hooks)
    }
  }
  return [ordered]@{
    schema_version = 1
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    extensions = $records
  }
}

function Save-State([string]$statePath, [object]$state) {
  Ensure-ParentDir $statePath
  $state.generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding UTF8
}

function Parse-HooksFromEntry([string]$entryPath) {
  if (-not (Test-Path $entryPath)) {
    return @()
  }
  $lines = Get-Content -Path $entryPath
  $hooks = @()
  foreach ($line in $lines) {
    $m = [regex]::Match([string]$line, '^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
    if ($m.Success) {
      $hooks += [string]$m.Groups[1].Value
    }
  }
  return @($hooks | Sort-Object -Unique)
}

function Get-StateRecordIndex([object[]]$extensions, [string]$name) {
  for ($i = 0; $i -lt $extensions.Count; $i++) {
    if ([string]$extensions[$i].name -eq $name) {
      return $i
    }
  }
  return -1
}

function New-StateRecord([string]$name, [string]$path, [string]$entryPath, [string]$entryHash, [object[]]$hooks) {
  return [pscustomobject]@{
    name = $name
    path = $path
    entry = $entryPath
    loaded = $false
    entry_hash = $entryHash
    loaded_at_utc = ""
    call_count = 0
    reload_count = 0
    last_call_at_utc = ""
    last_reload_at_utc = ""
    last_error = ""
    hooks = $hooks
  }
}

function Ensure-Record([object]$state, [string]$name, [string]$path, [string]$entryPath, [string]$entryHash, [object[]]$hooks) {
  $idx = Get-StateRecordIndex @($state.extensions) $name
  if ($idx -lt 0) {
    $state.extensions += New-StateRecord $name $path $entryPath $entryHash $hooks
    return ($state.extensions.Count - 1)
  }
  $state.extensions[$idx].path = $path
  $state.extensions[$idx].entry = $entryPath
  $state.extensions[$idx].entry_hash = $entryHash
  $state.extensions[$idx].hooks = $hooks
  return $idx
}

function Test-LuaExeAvailable([string]$luaExe) {
  $cmd = Get-Command $luaExe -ErrorAction SilentlyContinue
  return ($null -ne $cmd)
}

function Invoke-LuaSyntaxCheck([string]$luaExe, [string]$entryPath) {
  & $luaExe -e "assert(loadfile([[${entryPath}]]))" 2>$null | Out-Null
  return ([int]$LASTEXITCODE -eq 0)
}

function Invoke-LuaHook(
  [string]$luaExe,
  [string]$entryPath,
  [string]$hook,
  [string]$payloadJson
) {
  $luaSnippet = @"
local ok, mod = pcall(dofile, [[${entryPath}]])
if not ok then
  io.stderr:write(tostring(mod))
  os.exit(2)
end
local hook_name = [[${hook}]]
local fn = nil
if type(mod) == "table" then
  fn = mod[hook_name]
elseif type(_G[hook_name]) == "function" then
  fn = _G[hook_name]
end
if type(fn) ~= "function" then
  os.exit(3)
end
local payload = [[${payloadJson}]]
local call_ok, result = pcall(fn, payload)
if not call_ok then
  io.stderr:write(tostring(result))
  os.exit(4)
end
if result ~= nil then
  io.write(tostring(result))
end
"@
  $stdout = & $luaExe -e $luaSnippet 2>&1
  return [ordered]@{
    exit_code = [int]$LASTEXITCODE
    stdout = ($stdout -join [Environment]::NewLine).Trim()
  }
}

function Emit-Report(
  [string]$outputPath,
  [string]$commandName,
  [bool]$ok,
  [int]$reasonCode,
  [string]$packagesRoot,
  [string]$statePath,
  [hashtable]$state,
  [hashtable]$details
) {
  $extensions = @($state.extensions | Sort-Object -Property name)
  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    command = $commandName
    ok = $ok
    reason_code = $reasonCode
    packages_root = $packagesRoot
    state_path = $statePath
    loaded_count = @($extensions | Where-Object { [bool]$_.loaded }).Count
    extension_count = $extensions.Count
    details = $details
    extensions = $extensions
  }
  Ensure-ParentDir $outputPath
  $report | ConvertTo-Json -Depth 12 | Set-Content -Path $outputPath -Encoding UTF8
  return $report
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackagesRoot = Resolve-AbsolutePath -path $PackagesRoot -baseDir $repoRoot
$resolvedStatePath = Resolve-AbsolutePath -path $StatePath -baseDir $repoRoot

$state = Load-State $resolvedStatePath
$details = @{}
$failureReason = 0

try {
  if (-not (Test-Path $resolvedPackagesRoot)) {
    throw "packages root not found: $resolvedPackagesRoot"
  }

  switch ($Command) {
    "discover" {
      $found = @()
      $dirs = @(Get-ChildItem -Path $resolvedPackagesRoot -Directory -Force)
      foreach ($dir in $dirs) {
        $name = [string]$dir.Name
        if ($name.StartsWith(".")) {
          continue
        }
        $entryPath = Extension-EntryPath $resolvedPackagesRoot $name
        if (-not (Test-Path $entryPath)) {
          continue
        }
        $entryHash = (Get-FileHash -Algorithm SHA256 -Path $entryPath).Hash.ToLowerInvariant()
        $hooks = Parse-HooksFromEntry $entryPath
        [void](Ensure-Record $state $name $dir.FullName $entryPath $entryHash $hooks)
        $found += $name
      }
      $details["found_extensions"] = @($found | Sort-Object -Unique)
    }
    "load" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failureReason = Reason-InvalidArgument
        throw "load command requires -Name"
      }
      $target = $Name.Trim()
      $entryPath = Extension-EntryPath $resolvedPackagesRoot $target
      if (-not (Test-Path $entryPath)) {
        $failureReason = Reason-ExtensionMissing
        throw "extension entry not found: $entryPath"
      }
      $entryHash = (Get-FileHash -Algorithm SHA256 -Path $entryPath).Hash.ToLowerInvariant()
      $hooks = Parse-HooksFromEntry $entryPath
      $idx = Ensure-Record $state $target (Join-Path $resolvedPackagesRoot $target) $entryPath $entryHash $hooks

      if ($EnableLuaExecution) {
        if (-not (Test-LuaExeAvailable $LuaExe)) {
          $failureReason = Reason-LuaRuntimeUnavailable
          throw "lua runtime not found: $LuaExe"
        }
        if (-not (Invoke-LuaSyntaxCheck $LuaExe $entryPath)) {
          $failureReason = Reason-LuaExecutionFailure
          throw "lua syntax check failed for: $entryPath"
        }
      }

      $state.extensions[$idx].loaded = $true
      $state.extensions[$idx].loaded_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      $state.extensions[$idx].last_error = ""
      $details["loaded_extension"] = $target
      $details["hooks"] = @($hooks)
      $details["lua_execution"] = [bool]$EnableLuaExecution
    }
    "call" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failureReason = Reason-InvalidArgument
        throw "call command requires -Name"
      }
      $target = $Name.Trim()
      $idx = Get-StateRecordIndex @($state.extensions) $target
      if ($idx -lt 0) {
        $failureReason = Reason-StateMissing
        throw "extension not found in state: $target"
      }
      if (-not [bool]$state.extensions[$idx].loaded) {
        $failureReason = Reason-ExtensionNotLoaded
        throw "extension is not loaded: $target"
      }

      $hookName = if ([string]::IsNullOrWhiteSpace($Hook)) { "ping" } else { $Hook.Trim() }
      $details["called_extension"] = $target
      $details["hook"] = $hookName
      $details["lua_execution"] = [bool]$EnableLuaExecution

      if ($EnableLuaExecution) {
        if (-not (Test-LuaExeAvailable $LuaExe)) {
          $failureReason = Reason-LuaRuntimeUnavailable
          throw "lua runtime not found: $LuaExe"
        }
        $callResult = Invoke-LuaHook $LuaExe [string]$state.extensions[$idx].entry $hookName $PayloadJson
        $details["lua_call"] = $callResult
        if ([int]$callResult.exit_code -ne 0) {
          $failureReason = Reason-LuaExecutionFailure
          $state.extensions[$idx].last_error = [string]$callResult.stdout
          throw ("lua hook call failed (exit={0})" -f [int]$callResult.exit_code)
        }
      }

      $state.extensions[$idx].call_count = [int64]$state.extensions[$idx].call_count + 1
      $state.extensions[$idx].last_call_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      $state.extensions[$idx].last_error = ""
    }
    "hot_reload" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failureReason = Reason-InvalidArgument
        throw "hot_reload command requires -Name"
      }
      $target = $Name.Trim()
      $idx = Get-StateRecordIndex @($state.extensions) $target
      if ($idx -lt 0) {
        $failureReason = Reason-StateMissing
        throw "extension not found in state: $target"
      }
      if (-not [bool]$state.extensions[$idx].loaded) {
        $failureReason = Reason-ExtensionNotLoaded
        throw "extension is not loaded: $target"
      }
      $entryPath = [string]$state.extensions[$idx].entry
      if (-not (Test-Path $entryPath)) {
        $failureReason = Reason-ExtensionMissing
        throw "extension entry missing: $entryPath"
      }
      $nextHash = (Get-FileHash -Algorithm SHA256 -Path $entryPath).Hash.ToLowerInvariant()
      $currentHash = [string]$state.extensions[$idx].entry_hash
      $needsReload = ($nextHash -ne $currentHash) -or [bool]$ForceReload
      if (-not $needsReload) {
        $failureReason = Reason-ReloadNotNeeded
        throw "hot reload skipped: file hash unchanged"
      }
      if ($EnableLuaExecution) {
        if (-not (Test-LuaExeAvailable $LuaExe)) {
          $failureReason = Reason-LuaRuntimeUnavailable
          throw "lua runtime not found: $LuaExe"
        }
        if (-not (Invoke-LuaSyntaxCheck $LuaExe $entryPath)) {
          $failureReason = Reason-LuaExecutionFailure
          throw "lua syntax check failed for: $entryPath"
        }
      }
      $state.extensions[$idx].entry_hash = $nextHash
      $state.extensions[$idx].hooks = Parse-HooksFromEntry $entryPath
      $state.extensions[$idx].reload_count = [int64]$state.extensions[$idx].reload_count + 1
      $state.extensions[$idx].last_reload_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      $state.extensions[$idx].last_error = ""
      $details["reloaded_extension"] = $target
      $details["force"] = [bool]$ForceReload
      $details["old_hash"] = $currentHash
      $details["new_hash"] = $nextHash
    }
    "unload" {
      if ([string]::IsNullOrWhiteSpace($Name)) {
        $failureReason = Reason-InvalidArgument
        throw "unload command requires -Name"
      }
      $target = $Name.Trim()
      $idx = Get-StateRecordIndex @($state.extensions) $target
      if ($idx -lt 0) {
        $failureReason = Reason-StateMissing
        throw "extension not found in state: $target"
      }
      if (-not [bool]$state.extensions[$idx].loaded) {
        $failureReason = Reason-ExtensionNotLoaded
        throw "extension is not loaded: $target"
      }
      $state.extensions[$idx].loaded = $false
      $state.extensions[$idx].last_error = ""
      $details["unloaded_extension"] = $target
    }
    "status" {
      $details["state_only"] = $true
    }
  }
} catch {
  $msg = $_.Exception.Message
  if ($failureReason -eq 0) {
    $failureReason = Reason-UnknownFailure
  }
  $details["error"] = $msg
}

Save-State $resolvedStatePath $state
$ok = ($failureReason -eq 0)
$report = Emit-Report $OutputPath $Command $ok $failureReason $resolvedPackagesRoot $resolvedStatePath $state $details

if ($AsJson) {
  $report | ConvertTo-Json -Depth 12
} else {
  Write-Output ("LUA_LIFECYCLE_CMD={0}" -f $Command)
  Write-Output ("LUA_LIFECYCLE_OK={0}" -f $ok)
  Write-Output ("LUA_LIFECYCLE_REASON_CODE={0}" -f $failureReason)
  Write-Output ("LUA_LIFECYCLE_PACKAGES_ROOT={0}" -f $resolvedPackagesRoot)
  Write-Output ("LUA_LIFECYCLE_STATE={0}" -f $resolvedStatePath)
  Write-Output ("LUA_LIFECYCLE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)
  Write-Output ("LUA_LIFECYCLE_EXTENSION_COUNT={0}" -f $report.extension_count)
  Write-Output ("LUA_LIFECYCLE_LOADED_COUNT={0}" -f $report.loaded_count)
}

if (-not $ok) {
  exit 1
}
