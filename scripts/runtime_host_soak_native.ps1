param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe",

  [Parameter(Mandatory = $false)]
  [int]$DurationSeconds = 60,

  [Parameter(Mandatory = $false)]
  [double]$MaxFailureRate = 0.01,

  [Parameter(Mandatory = $false)]
  [double]$MinThroughputRps = 0.5,

  [Parameter(Mandatory = $false)]
  [double]$MaxP95LatencyMs = 2000.0,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/runtime_host_soak_native_report.json",

  [Parameter(Mandatory = $false)]
  [int]$ProbeTcpPort = 9527,

  [Parameter(Mandatory = $false)]
  [int]$ProbeTimeoutMs = 700,

  [Parameter(Mandatory = $false)]
  [int]$WarmupMilliseconds = 1500
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Get-P95([double[]]$values) {
  if ($values.Count -eq 0) {
    return 0.0
  }
  $sorted = $values | Sort-Object
  $rawIndex = [Math]::Ceiling($sorted.Count * 0.95) - 1
  $idx = [int][Math]::Max(0, [Math]::Min($rawIndex, $sorted.Count - 1))
  return [double]$sorted[$idx]
}

function Test-TcpPort([string]$targetHost, [int]$port, [int]$timeoutMs) {
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($targetHost, $port)
    if (-not $task.Wait($timeoutMs)) {
      $watch.Stop()
      return [ordered]@{ ok = $false; latency_ms = [double]$watch.Elapsed.TotalMilliseconds }
    }
    $ok = $client.Connected
    $watch.Stop()
    return [ordered]@{ ok = $ok; latency_ms = [double]$watch.Elapsed.TotalMilliseconds }
  } catch {
    $watch.Stop()
    return [ordered]@{ ok = $false; latency_ms = [double]$watch.Elapsed.TotalMilliseconds }
  } finally {
    $client.Dispose()
  }
}

if (-not (Test-Path $BinaryPath)) {
  throw "native runtime binary not found: $BinaryPath"
}
if ($DurationSeconds -le 0) {
  throw "DurationSeconds must be > 0"
}

$proc = Start-Process -FilePath $BinaryPath -PassThru
Start-Sleep -Milliseconds $WarmupMilliseconds
$proc.Refresh()

$bootExited = $proc.HasExited
$bootExitCode = if ($bootExited) { [int]$proc.ExitCode } else { 0 }

$attempts = 0
$successes = 0
$failures = 0
$latencies = New-Object 'System.Collections.Generic.List[double]'
$errorCodes = New-Object 'System.Collections.Generic.List[int]'
$aliveUntilEnd = -not $bootExited
$wall = [System.Diagnostics.Stopwatch]::StartNew()

if (-not $bootExited) {
  while ($wall.Elapsed.TotalSeconds -lt $DurationSeconds) {
    $attempts += 1
    $proc.Refresh()
    if ($proc.HasExited) {
      $aliveUntilEnd = $false
      $failures += 1
      $errorCodes.Add([int]$proc.ExitCode) | Out-Null
      break
    }

    $probe = Test-TcpPort -targetHost "127.0.0.1" -port $ProbeTcpPort -timeoutMs $ProbeTimeoutMs
    $latencies.Add([double]$probe.latency_ms) | Out-Null
    if ([bool]$probe.ok) {
      $successes += 1
    } else {
      $failures += 1
    }
    Start-Sleep -Milliseconds 1000
  }
}
$wall.Stop()

$proc.Refresh()
if (-not $proc.HasExited) {
  Stop-Process -Id $proc.Id -Force
}

$elapsedSeconds = [double][Math]::Max(0.001, $wall.Elapsed.TotalSeconds)
$failureRate = if ($attempts -gt 0) { [double]$failures / [double]$attempts } else { 1.0 }
$throughputRps = [double]$attempts / $elapsedSeconds
$latencyP95Ms = Get-P95 -values $latencies.ToArray()
$latencyAvgMs = if ($latencies.Count -gt 0) {
  [double]($latencies.ToArray() | Measure-Object -Average).Average
} else {
  0.0
}

$pass = (-not $bootExited) `
  -and $aliveUntilEnd `
  -and ($attempts -gt 0) `
  -and ($failureRate -le $MaxFailureRate) `
  -and ($throughputRps -ge $MinThroughputRps) `
  -and ($latencyP95Ms -le $MaxP95LatencyMs)

$report = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = $pass
  binary_path = (Resolve-Path $BinaryPath).Path
  duration_seconds = $DurationSeconds
  elapsed_seconds = $elapsedSeconds
  thresholds = [ordered]@{
    max_failure_rate = $MaxFailureRate
    min_throughput_rps = $MinThroughputRps
    max_p95_latency_ms = $MaxP95LatencyMs
  }
  boot = [ordered]@{
    exited_during_warmup = $bootExited
    warmup_exit_code = $bootExitCode
    warmup_ms = $WarmupMilliseconds
  }
  probe = [ordered]@{
    tcp_port = $ProbeTcpPort
    timeout_ms = $ProbeTimeoutMs
  }
  metrics = [ordered]@{
    attempts = $attempts
    successes = $successes
    failures = $failures
    failure_rate = $failureRate
    throughput_rps = $throughputRps
    latency_avg_ms = $latencyAvgMs
    latency_p95_ms = $latencyP95Ms
    alive_until_end = $aliveUntilEnd
    nonzero_exit_codes = $errorCodes
  }
}

Ensure-ParentDir $OutputPath
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("SOAK_NATIVE_OK={0}" -f $pass)
Write-Output ("SOAK_NATIVE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $pass) {
  exit 1
}
