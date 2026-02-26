param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "",

  [Parameter(Mandatory = $false)]
  [switch]$Detached
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$scriptParentDir = Resolve-AbsolutePath -path ".." -baseDir $scriptDir

$candidates = @()
if ([string]::IsNullOrWhiteSpace($BinaryPath)) {
  $candidates += (Resolve-AbsolutePath -path "bin/freekill-asio-sengoo-runtime.exe" -baseDir $scriptParentDir)
  $candidates += (Resolve-AbsolutePath -path "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe" -baseDir $scriptParentDir)
} else {
  $candidates += (Resolve-AbsolutePath -path $BinaryPath -baseDir $scriptParentDir)
}

$resolved = ""
foreach ($candidate in $candidates) {
  if (Test-Path $candidate) {
    $resolved = (Resolve-Path $candidate).Path
    break
  }
}

if ([string]::IsNullOrWhiteSpace($resolved)) {
  throw ("native runtime binary not found. tried: {0}" -f ($candidates -join "; "))
}

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
