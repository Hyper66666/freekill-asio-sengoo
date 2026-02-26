param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path $BinaryPath)) {
  throw "native runtime binary not found: $BinaryPath"
}

$resolved = (Resolve-Path $BinaryPath).Path
$proc = Start-Process -FilePath $resolved -PassThru -Wait
$exitCode = [int]$proc.ExitCode
$healthy = $exitCode -eq 0

Write-Output ("NATIVE_HEALTH_OK={0}" -f $healthy)
Write-Output ("NATIVE_HEALTH_EXIT={0}" -f $exitCode)
Write-Output ("NATIVE_HEALTH_BINARY={0}" -f $resolved)

if (-not $healthy) {
  exit 1
}
