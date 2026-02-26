param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "",

  [Parameter(Mandatory = $false)]
  [int]$TcpPort = 9527,

  [Parameter(Mandatory = $false)]
  [int]$ConnectTimeoutMs = 500
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

function Test-TcpPort([string]$targetHost, [int]$port, [int]$timeoutMs) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($targetHost, $port)
    if (-not $task.Wait($timeoutMs)) {
      return $false
    }
    return $client.Connected
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
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

$processName = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
$runningProcs = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
$processHealthy = $runningProcs.Count -gt 0
$portHealthy = $false
if ($processHealthy -and $TcpPort -gt 0 -and $TcpPort -le 65535) {
  $portHealthy = Test-TcpPort -targetHost "127.0.0.1" -port $TcpPort -timeoutMs $ConnectTimeoutMs
}
$healthy = $processHealthy -and $portHealthy

Write-Output ("NATIVE_HEALTH_OK={0}" -f $healthy)
Write-Output ("NATIVE_HEALTH_BINARY={0}" -f $resolved)
Write-Output ("NATIVE_HEALTH_PROCESS_NAME={0}" -f $processName)
Write-Output ("NATIVE_HEALTH_PROCESS_COUNT={0}" -f $runningProcs.Count)
Write-Output ("NATIVE_HEALTH_TCP_PORT={0}" -f $TcpPort)
Write-Output ("NATIVE_HEALTH_PORT_OPEN={0}" -f $portHealthy)

if (-not $healthy) {
  exit 1
}
