param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host_watchdog_smoke_report.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function Wait-TcpReply([string]$EndpointHost, [int]$Port, [int]$timeoutMs, [string]$expectedReply) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      $reply = Invoke-TcpCommand -EndpointHost $EndpointHost -Port $Port -Command "M1_CONN_PING"
      if ($reply -eq $expectedReply) {
        return $reply
      }
    }
    catch {
      # retry
    }
    Start-Sleep -Milliseconds 150
  }
  throw ("timeout waiting tcp reply {0} at {1}:{2}" -f $expectedReply, $EndpointHost, $Port)
}

function Invoke-TcpCommand([string]$EndpointHost, [int]$Port, [string]$Command) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $client.Connect($EndpointHost, $Port)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 2500
    $stream.WriteTimeout = 2500
    $payload = [System.Text.Encoding]::UTF8.GetBytes($Command + "`n")
    $stream.Write($payload, 0, $payload.Length)
    $stream.Flush()

    $bytes = New-Object "System.Collections.Generic.List[byte]"
    while ($true) {
      $next = $stream.ReadByte()
      if ($next -lt 0 -or $next -eq 10) {
        break
      }
      if ($next -ne 13) {
        $bytes.Add([byte]$next)
      }
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
  }
  finally {
    $client.Dispose()
  }
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

$tmpRoot = ".tmp/runtime_host_watchdog_smoke"
$serverScript = "scripts/runtime_host_server.py"
$watchdogScript = "scripts/runtime_host_watchdog.py"
if (-not (Test-Path $serverScript)) {
  throw "missing runtime host server script: $serverScript"
}
if (-not (Test-Path $watchdogScript)) {
  throw "missing watchdog script: $watchdogScript"
}

$endpointHost = "127.0.0.1"
$tcpPort = Get-FreeTcpPort
$udpPort = $tcpPort + 1
$dbPath = Join-Path $tmpRoot "runtime.sqlite"
$luaPath = Join-Path $tmpRoot "runtime.lua"
$configPath = Join-Path $tmpRoot "runtime_config.json"
$statusPath = Join-Path $tmpRoot "watchdog_status.json"
$eventLogPath = Join-Path $tmpRoot "watchdog_events.jsonl"
$stdoutLog = Join-Path $tmpRoot "watchdog.stdout.log"
$stderrLog = Join-Path $tmpRoot "watchdog.stderr.log"

New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
"-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $luaPath -Encoding UTF8

$cfg = [ordered]@{
  host = $endpointHost
  tcp_port = $tcpPort
  udp_port = $udpPort
  runtime_name = "watchdog-smoke"
  db_path = $dbPath
  thread_count = 4
  tick_interval_ms = 20
  task_budget = 256
  lua_script_path = $luaPath
  lua_command = ""
  drift_mode = "none"
}
$cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding UTF8

$proc = $null
$report = $null
$watchdogExitCode = -1
try {
  $args = @(
    $watchdogScript,
    "--python-exe", $PythonExe,
    "--server-script", $serverScript,
    "--config-json", $configPath,
    "--health-host", $endpointHost,
    "--health-tcp-port", $tcpPort,
    "--health-udp-port", $udpPort,
    "--health-interval-s", 1,
    "--start-grace-s", 1,
    "--max-consecutive-health-failures", 2,
    "--restart-delay-s", 0.5,
    "--max-restarts", 1,
    "--status-path", $statusPath,
    "--event-log-path", $eventLogPath
  )

  $proc = Start-Process -FilePath $PythonExe `
    -ArgumentList $args `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

  Wait-TcpReply -EndpointHost $endpointHost -Port $tcpPort -timeoutMs 9000 -expectedReply "M1_CONN_PONG" | Out-Null
  $stop1 = Invoke-TcpCommand -EndpointHost $endpointHost -Port $tcpPort -Command "__STOP__"
  Wait-TcpReply -EndpointHost $endpointHost -Port $tcpPort -timeoutMs 10000 -expectedReply "M1_CONN_PONG" | Out-Null
  $stop2 = Invoke-TcpCommand -EndpointHost $endpointHost -Port $tcpPort -Command "__STOP__"

  $exited = $proc.WaitForExit(12000)
  if (-not $proc.HasExited) {
    $proc.Kill()
    $proc.WaitForExit(4000) | Out-Null
  }
  if ($proc.HasExited) {
    $watchdogExitCode = [int]$proc.ExitCode
  }

  if (-not (Test-Path $statusPath)) {
    throw "missing watchdog status file: $statusPath"
  }

  $status = Get-Content -Raw $statusPath | ConvertFrom-Json
  $restartCount = [int]$status.restart_count
  $pass = ($stop1 -eq "__STOP_OK__") `
    -and ($stop2 -eq "__STOP_OK__") `
    -and ($restartCount -ge 1) `
    -and ($exited -or $watchdogExitCode -eq 2)

  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = $pass
    host = $endpointHost
    tcp_port = $tcpPort
    udp_port = $udpPort
    stop_reply_1 = $stop1
    stop_reply_2 = $stop2
    watchdog_exit_code = $watchdogExitCode
    watchdog_restart_count = $restartCount
    status = $status
    paths = [ordered]@{
      config = (Resolve-Path $configPath).Path
      status = (Resolve-Path $statusPath).Path
      events = (Resolve-Path $eventLogPath).Path
      stdout = (Resolve-Path $stdoutLog).Path
      stderr = (Resolve-Path $stderrLog).Path
    }
  }
}
finally {
  if ($null -ne $proc) {
    try {
      if (-not $proc.HasExited) {
        $proc.Kill()
      }
    }
    catch {
      # best effort
    }
  }
}

Ensure-ParentDir $OutputPath
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8

if (-not [bool]$report.pass) {
  throw "runtime host watchdog smoke failed; report: $OutputPath"
}

Write-Output "PASS runtime host watchdog smoke"
Write-Output ("REPORT={0}" -f (Resolve-Path $OutputPath).Path)
