param(
  [Parameter(Mandatory = $false)]
  [string]$TaskName = "FreeKillRuntimeHostWatchdog"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
  Write-Output ("SCHEDULED_TASK_NOT_FOUND={0}" -f $TaskName)
  exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output ("SCHEDULED_TASK_REMOVED={0}" -f $TaskName)
