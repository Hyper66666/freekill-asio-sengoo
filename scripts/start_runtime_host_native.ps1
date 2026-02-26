param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe",

  [Parameter(Mandatory = $false)]
  [switch]$Detached
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path $BinaryPath)) {
  throw "native runtime binary not found: $BinaryPath"
}

$resolved = (Resolve-Path $BinaryPath).Path
if ($Detached) {
  $proc = Start-Process -FilePath $resolved -PassThru
  Write-Output ("NATIVE_RUNTIME_STARTED_PID={0}" -f $proc.Id)
  Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
  exit 0
}

$proc = Start-Process -FilePath $resolved -PassThru -Wait
$exitCode = [int]$proc.ExitCode
Write-Output ("NATIVE_RUNTIME_EXIT={0}" -f $exitCode)
Write-Output ("NATIVE_RUNTIME_BINARY={0}" -f $resolved)
exit $exitCode
