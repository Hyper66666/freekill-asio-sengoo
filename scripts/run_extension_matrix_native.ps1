param(
  [Parameter(Mandatory = $false)]
  [string]$PackageManagerScriptPath = "scripts/package_manager_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$LuaLifecycleScriptPath = "scripts/lua_extension_lifecycle_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$TargetsPath = "scripts/fixtures/extension_matrix_targets.json",

  [Parameter(Mandatory = $false)]
  [switch]$UseLocalFixture,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/extension_matrix_native_report.json"
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

function Get-OptionalString([object]$obj, [string]$name, [string]$fallback) {
  if ($null -eq $obj) { return $fallback }
  $prop = $obj.PSObject.Properties[$name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $fallback }
  return [string]$prop.Value
}

function Get-OptionalBool([object]$obj, [string]$name, [bool]$fallback) {
  if ($null -eq $obj) { return $fallback }
  $prop = $obj.PSObject.Properties[$name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $fallback }
  return [bool]$prop.Value
}

function Is-LocalTargetUrl([string]$url) {
  if ([string]::IsNullOrWhiteSpace($url)) {
    return $false
  }
  $trimmed = $url.Trim()
  if (Test-Path $trimmed) {
    return $true
  }
  if ($trimmed.StartsWith("file://")) {
    return $true
  }
  return $false
}

function New-LocalExtensionRepo([string]$remoteRoot, [string]$name) {
  $repoDir = Join-Path $remoteRoot $name
  New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $repoDir "lua/server/rpc") -Force | Out-Null

  @"
local M = {}
function M.ping(payload)
  return "${name}:pong:" .. tostring(payload)
end
return M
"@ | Set-Content -Path (Join-Path $repoDir "lua/server/rpc/entry.lua") -Encoding UTF8
  Set-Content -Path (Join-Path $repoDir "README.md") -Encoding UTF8 -Value ("# " + $name)

  & git -C $repoDir init | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "failed to init local git repo: $repoDir"
  }
  & git -C $repoDir add . | Out-Null
  & git -C $repoDir -c user.name="matrix-smoke" -c user.email="matrix-smoke@example.invalid" commit -m "init $name" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "failed to commit local git repo: $repoDir"
  }

  return [ordered]@{
    name = $name
    url = ([System.Uri]::new($repoDir)).AbsoluteUri
    supports_disable = ($name -ne "freekill-core")
    source = "local-fixture"
  }
}

function Load-ExtensionTargets([string]$targetsPath) {
  if (-not (Test-Path $targetsPath)) {
    return @()
  }
  $raw = Get-Content -Raw -Path $targetsPath
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @()
  }
  $parsed = $raw | ConvertFrom-Json
  $targetsRaw = @()
  if ($parsed -is [System.Array]) {
    $targetsRaw = @($parsed)
  } else {
    $prop = $parsed.PSObject.Properties["targets"]
    if ($null -ne $prop -and $null -ne $prop.Value) {
      $targetsRaw = @($prop.Value)
    }
  }

  $targets = @()
  foreach ($t in $targetsRaw) {
    $name = Get-OptionalString $t "name" ""
    $url = Get-OptionalString $t "url" ""
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($url)) {
      continue
    }
    $supportsDisable = Get-OptionalBool $t "supports_disable" ($name -ne "freekill-core")
    $priority = Get-OptionalString $t "priority" "P1"
    $targets += [ordered]@{
      name = $name
      url = $url
      supports_disable = $supportsDisable
      priority = $priority
      source = "targets-file"
    }
  }
  return @($targets)
}

function Invoke-PackageManager(
  [string]$scriptPath,
  [string]$packagesRoot,
  [string]$commandName,
  [string]$reportPath,
  [int[]]$expectedExits,
  [string]$name,
  [string]$url
) {
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $scriptPath,
    "-Command", $commandName,
    "-PackagesRoot", $packagesRoot,
    "-OutputPath", $reportPath,
    "-AsJson"
  )
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    $args += @("-Name", $name)
  }
  if (-not [string]::IsNullOrWhiteSpace($url)) {
    $args += @("-Url", $url)
  }
  $raw = & powershell @args
  $exitCode = [int]$LASTEXITCODE
  if ($expectedExits -notcontains $exitCode) {
    throw ("package command {0} expected exits [{1}], actual {2}" -f $commandName, ($expectedExits -join ","), $exitCode)
  }
  $jsonText = ($raw -join [Environment]::NewLine).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw ("package command {0} returned empty output" -f $commandName)
  }
  return ($jsonText | ConvertFrom-Json)
}

function Invoke-Lifecycle(
  [string]$scriptPath,
  [string]$packagesRoot,
  [string]$statePath,
  [string]$commandName,
  [string]$name,
  [string]$hook,
  [int[]]$expectedExits,
  [string]$reportPath
) {
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $scriptPath,
    "-Command", $commandName,
    "-PackagesRoot", $packagesRoot,
    "-StatePath", $statePath,
    "-OutputPath", $reportPath,
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
  if ($expectedExits -notcontains $exitCode) {
    throw ("lifecycle command {0} expected exits [{1}], actual {2}" -f $commandName, ($expectedExits -join ","), $exitCode)
  }
  $jsonText = ($raw -join [Environment]::NewLine).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw ("lifecycle command {0} returned empty output" -f $commandName)
  }
  return ($jsonText | ConvertFrom-Json)
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackageManagerScriptPath = Resolve-AbsolutePath -path $PackageManagerScriptPath -baseDir $repoRoot
$resolvedLuaLifecycleScriptPath = Resolve-AbsolutePath -path $LuaLifecycleScriptPath -baseDir $repoRoot
$resolvedTargetsPath = Resolve-AbsolutePath -path $TargetsPath -baseDir $repoRoot

if (-not (Test-Path $resolvedPackageManagerScriptPath)) {
  throw "package manager script not found: $resolvedPackageManagerScriptPath"
}
if (-not (Test-Path $resolvedLuaLifecycleScriptPath)) {
  throw "lua lifecycle script not found: $resolvedLuaLifecycleScriptPath"
}
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
  throw "git command not found"
}

$tmpRoot = Resolve-AbsolutePath -path ".tmp/extension_matrix_native" -baseDir $repoRoot
if (Test-Path $tmpRoot) {
  Remove-Item -Recurse -Force $tmpRoot
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$remoteRoot = Join-Path $tmpRoot "remote"
$packagesRoot = Join-Path $tmpRoot "packages"
$reportsRoot = Join-Path $tmpRoot "reports"
$luaStatePath = Join-Path $tmpRoot "lua_state.json"
New-Item -ItemType Directory -Path $remoteRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportsRoot -Force | Out-Null

$extensions = @()
$targetMode = "local-fixture"
if (-not [bool]$UseLocalFixture) {
  $extensions = @(Load-ExtensionTargets $resolvedTargetsPath)
  if ($extensions.Count -gt 0) {
    $targetMode = "targets-file"
  }
}

if ($extensions.Count -eq 0) {
  $coreRepo = New-LocalExtensionRepo -remoteRoot $remoteRoot -name "freekill-core"
  $extRepo = New-LocalExtensionRepo -remoteRoot $remoteRoot -name "ext-sample"
  $extensions = @($coreRepo, $extRepo)
}

$globalSteps = [ordered]@{}
$globalSteps.init = Invoke-PackageManager `
  -scriptPath $resolvedPackageManagerScriptPath `
  -packagesRoot $packagesRoot `
  -commandName "init" `
  -reportPath (Join-Path $reportsRoot "00-init.json") `
  -expectedExits @(0) `
  -name "" `
  -url ""

$extensionResults = @()
foreach ($ext in $extensions) {
  $name = [string]$ext.name
  $supportsDisable = [bool]$ext.supports_disable
  $url = [string]$ext.url
  $isLocalTargetUrl = Is-LocalTargetUrl $url
  $priority = Get-OptionalString $ext "priority" "P1"
  $source = Get-OptionalString $ext "source" $targetMode

  $steps = [ordered]@{}
  $blockedReasons = New-Object System.Collections.Generic.List[string]
  $extensionPass = $true

  try {
    $steps.install = Invoke-PackageManager `
      -scriptPath $resolvedPackageManagerScriptPath `
      -packagesRoot $packagesRoot `
      -commandName "install" `
      -reportPath (Join-Path $reportsRoot ("10-install-{0}.json" -f $name)) `
      -expectedExits @(0) `
      -name "" `
      -url $url

    if ($supportsDisable) {
      $steps.disable = Invoke-PackageManager `
        -scriptPath $resolvedPackageManagerScriptPath `
        -packagesRoot $packagesRoot `
        -commandName "disable" `
        -reportPath (Join-Path $reportsRoot ("11-disable-{0}.json" -f $name)) `
        -expectedExits @(0) `
        -name $name `
        -url ""
      $steps.enable = Invoke-PackageManager `
        -scriptPath $resolvedPackageManagerScriptPath `
        -packagesRoot $packagesRoot `
        -commandName "enable" `
        -reportPath (Join-Path $reportsRoot ("12-enable-{0}.json" -f $name)) `
        -expectedExits @(0) `
        -name $name `
        -url ""
    }

    $steps.discover = Invoke-Lifecycle `
      -scriptPath $resolvedLuaLifecycleScriptPath `
      -packagesRoot $packagesRoot `
      -statePath $luaStatePath `
      -commandName "discover" `
      -name "" `
      -hook "" `
      -expectedExits @(0) `
      -reportPath (Join-Path $reportsRoot ("20-discover-{0}.json" -f $name))

    $steps.load = Invoke-Lifecycle `
      -scriptPath $resolvedLuaLifecycleScriptPath `
      -packagesRoot $packagesRoot `
      -statePath $luaStatePath `
      -commandName "load" `
      -name $name `
      -hook "" `
      -expectedExits @(0) `
      -reportPath (Join-Path $reportsRoot ("21-load-{0}.json" -f $name))

    $steps.call = Invoke-Lifecycle `
      -scriptPath $resolvedLuaLifecycleScriptPath `
      -packagesRoot $packagesRoot `
      -statePath $luaStatePath `
      -commandName "call" `
      -name $name `
      -hook "ping" `
      -expectedExits @(0) `
      -reportPath (Join-Path $reportsRoot ("22-call-{0}.json" -f $name))

    $entryPath = Join-Path $packagesRoot ("{0}/lua/server/rpc/entry.lua" -f $name)
    Add-Content -Path $entryPath -Encoding UTF8 -Value "`n-- matrix hot reload marker"

    $steps.hot_reload = Invoke-Lifecycle `
      -scriptPath $resolvedLuaLifecycleScriptPath `
      -packagesRoot $packagesRoot `
      -statePath $luaStatePath `
      -commandName "hot_reload" `
      -name $name `
      -hook "" `
      -expectedExits @(0) `
      -reportPath (Join-Path $reportsRoot ("23-hot-reload-{0}.json" -f $name))

    $steps.unload = Invoke-Lifecycle `
      -scriptPath $resolvedLuaLifecycleScriptPath `
      -packagesRoot $packagesRoot `
      -statePath $luaStatePath `
      -commandName "unload" `
      -name $name `
      -hook "" `
      -expectedExits @(0) `
      -reportPath (Join-Path $reportsRoot ("24-unload-{0}.json" -f $name))

    $upgradeExpected = if ($targetMode -eq "targets-file" -and -not $isLocalTargetUrl) { @(0) } else { @(0, 1) }
    $steps.upgrade = Invoke-PackageManager `
      -scriptPath $resolvedPackageManagerScriptPath `
      -packagesRoot $packagesRoot `
      -commandName "upgrade" `
      -reportPath (Join-Path $reportsRoot ("25-upgrade-{0}.json" -f $name)) `
      -expectedExits $upgradeExpected `
      -name $name `
      -url ""

    if (($targetMode -ne "targets-file" -or $isLocalTargetUrl) -and [int]$steps.upgrade.reason_code -ne 0 -and [int]$steps.upgrade.reason_code -ne 9302) {
      throw ("upgrade failed with unexpected reason code {0} for {1}" -f [int]$steps.upgrade.reason_code, $name)
    }
    if ($targetMode -eq "targets-file" -and -not $isLocalTargetUrl -and [int]$steps.upgrade.reason_code -ne 0) {
      throw ("upgrade failed for real target {0} with reason code {1}" -f $name, [int]$steps.upgrade.reason_code)
    }
  } catch {
    $extensionPass = $false
    [void]$blockedReasons.Add($_.Exception.Message)
  }

  $extensionResults += [ordered]@{
    extension = $name
    source = $source
    priority = $priority
    url = $url
    local_target_url = $isLocalTargetUrl
    os = "windows"
    runtime_mode = "native"
    pass = $extensionPass
    status = if ($extensionPass) { "pass" } else { "blocked" }
    blockers = @($blockedReasons.ToArray())
    steps = $steps
  }
}

$blocked = @($extensionResults | Where-Object { -not [bool]$_.pass })
$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = ($blocked.Count -eq 0)
  target_mode = $targetMode
  targets_path = $resolvedTargetsPath
  matrix = [ordered]@{
    dimensions = @("extension", "scenario", "os", "runtime_mode")
    os = "windows"
    runtime_mode = "native"
  }
  summary = [ordered]@{
    total_extensions = $extensionResults.Count
    passed_extensions = $extensionResults.Count - $blocked.Count
    blocked_extensions = $blocked.Count
  }
  global_steps = $globalSteps
  extensions = $extensionResults
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 16 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("EXTENSION_MATRIX_PASS={0}" -f [bool]$summary.pass)
Write-Output ("EXTENSION_MATRIX_MODE={0}" -f $targetMode)
Write-Output ("EXTENSION_MATRIX_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not [bool]$summary.pass) {
  exit 1
}
