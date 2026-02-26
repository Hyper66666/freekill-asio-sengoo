param(
  [Parameter(Mandatory = $false)]
  [string]$TaskName = "FreeKillRuntimeHostNative",

  [Parameter(Mandatory = $false)]
  [string]$RepoRoot = "",

  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "",

  [Parameter(Mandatory = $false)]
  [string]$StartScriptPath = "",

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

function Resolve-FirstExistingPath([string[]]$candidates, [string]$errorPrefix) {
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return (Resolve-Path $candidate).Path
    }
  }
  $joined = ($candidates -join "; ")
  throw "$errorPrefix. tried: $joined"
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  Resolve-AbsolutePath -path ".." -baseDir $scriptDir
} else {
  Resolve-AbsolutePath -path $RepoRoot -baseDir (Get-Location).Path
}

$binaryCandidates = @()
if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
  $binaryCandidates += (Resolve-AbsolutePath -path "bin/freekill-asio-sengoo-runtime.exe" -baseDir $resolvedRepoRoot)
  $binaryCandidates += (Resolve-AbsolutePath -path "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe" -baseDir $resolvedRepoRoot)
} else {
  $binaryCandidates += (Resolve-AbsolutePath -path $BinaryPath -baseDir $resolvedRepoRoot)
}
$resolvedBinaryPath = Resolve-FirstExistingPath -candidates $binaryCandidates -errorPrefix "native runtime binary not found"

$startScriptCandidates = @()
if ([string]::IsNullOrWhiteSpace($StartScriptPath)) {
  $startScriptCandidates += (Resolve-AbsolutePath -path "scripts/start_runtime_host_native.ps1" -baseDir $resolvedRepoRoot)
  $startScriptCandidates += (Resolve-AbsolutePath -path "start_runtime_host.ps1" -baseDir $scriptDir)
  $startScriptCandidates += (Resolve-AbsolutePath -path "start_runtime_host_native.ps1" -baseDir $scriptDir)
} else {
  $startScriptCandidates += (Resolve-AbsolutePath -path $StartScriptPath -baseDir $resolvedRepoRoot)
}
$startScript = Resolve-FirstExistingPath -candidates $startScriptCandidates -errorPrefix "native start script not found"

$actionArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$startScript`"",
  "-BinaryPath", "`"$resolvedBinaryPath`""
) -join " "

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $actionArgs -WorkingDirectory $resolvedRepoRoot
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
  -Description "FreeKill native runtime host" | Out-Null

if ($StartNow) {
  Start-ScheduledTask -TaskName $TaskName
}

Write-Output "NATIVE_SCHEDULED_TASK_INSTALLED"
Write-Output ("TASK_NAME={0}" -f $TaskName)
Write-Output ("REPO_ROOT={0}" -f $resolvedRepoRoot)
Write-Output ("BINARY_PATH={0}" -f $resolvedBinaryPath)
Write-Output ("START_SCRIPT={0}" -f $startScript)
