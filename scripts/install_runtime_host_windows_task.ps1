param(
  [Parameter(Mandatory = $false)]
  [string]$TaskName = "FreeKillRuntimeHostWatchdog",

  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$RepoRoot = ".",

  [Parameter(Mandatory = $false)]
  [string]$ConfigJsonPath = "scripts/runtime_host.config.example.json",

  [Parameter(Mandatory = $false)]
  [string]$HealthHost = "127.0.0.1",

  [Parameter(Mandatory = $false)]
  [int]$HealthTcpPort = 0,

  [Parameter(Mandatory = $false)]
  [int]$HealthUdpPort = 0,

  [Parameter(Mandatory = $false)]
  [switch]$RunAsCurrentUser,

  [Parameter(Mandatory = $false)]
  [switch]$StartNow,

  [Parameter(Mandatory = $false)]
  [switch]$Force
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

$resolvedRepoRoot = Resolve-AbsolutePath -path $RepoRoot -baseDir (Get-Location).Path
$resolvedConfigPath = Resolve-AbsolutePath -path $ConfigJsonPath -baseDir $resolvedRepoRoot
$watchdogPath = Resolve-AbsolutePath -path "scripts/runtime_host_watchdog.py" -baseDir $resolvedRepoRoot
$serverPath = Resolve-AbsolutePath -path "scripts/runtime_host_server.py" -baseDir $resolvedRepoRoot

if (-not (Test-Path $resolvedConfigPath)) {
  throw "config json not found: $resolvedConfigPath"
}
if (-not (Test-Path $watchdogPath)) {
  throw "watchdog script not found: $watchdogPath"
}
if (-not (Test-Path $serverPath)) {
  throw "server script not found: $serverPath"
}

$runtimeTmp = Join-Path $resolvedRepoRoot ".tmp/runtime_host_service"
New-Item -ItemType Directory -Path $runtimeTmp -Force | Out-Null
$statusPath = Join-Path $runtimeTmp "watchdog_status.json"
$eventLogPath = Join-Path $runtimeTmp "watchdog_events.jsonl"
$stdoutLogPath = Join-Path $runtimeTmp "watchdog_server.stdout.log"
$stderrLogPath = Join-Path $runtimeTmp "watchdog_server.stderr.log"

$argParts = @(
  "`"$watchdogPath`"",
  "--python-exe", "`"$PythonExe`"",
  "--server-script", "`"$serverPath`"",
  "--config-json", "`"$resolvedConfigPath`"",
  "--health-host", "`"$HealthHost`"",
  "--status-path", "`"$statusPath`"",
  "--event-log-path", "`"$eventLogPath`"",
  "--stdout-log-path", "`"$stdoutLogPath`"",
  "--stderr-log-path", "`"$stderrLogPath`""
)
if ($HealthTcpPort -gt 0) {
  $argParts += @("--health-tcp-port", $HealthTcpPort)
}
if ($HealthUdpPort -gt 0) {
  $argParts += @("--health-udp-port", $HealthUdpPort)
}
$argument = $argParts -join " "

$action = New-ScheduledTaskAction -Execute $PythonExe -Argument $argument -WorkingDirectory $resolvedRepoRoot
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
  -StartWhenAvailable `
  -RestartCount 999 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

if ($RunAsCurrentUser) {
  $principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType InteractiveToken `
    -RunLevel Highest
}
else {
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existing) {
  if (-not $Force) {
    throw "scheduled task already exists: $TaskName (use -Force to replace)"
  }
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "FreeKill runtime host watchdog" | Out-Null

if ($StartNow) {
  Start-ScheduledTask -TaskName $TaskName
}

Write-Output "SCHEDULED_TASK_INSTALLED"
Write-Output ("TASK_NAME={0}" -f $TaskName)
Write-Output ("REPO_ROOT={0}" -f $resolvedRepoRoot)
Write-Output ("CONFIG_JSON={0}" -f $resolvedConfigPath)
