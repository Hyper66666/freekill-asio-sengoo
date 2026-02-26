param(
  [Parameter(Mandatory = $false)]
  [string]$TaskName = "FreeKillRuntimeHostNative"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -eq $existing) {
  Write-Output ("NATIVE_SCHEDULED_TASK_NOT_FOUND={0}" -f $TaskName)
  exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "NATIVE_SCHEDULED_TASK_UNINSTALLED"
Write-Output ("TASK_NAME={0}" -f $TaskName)
