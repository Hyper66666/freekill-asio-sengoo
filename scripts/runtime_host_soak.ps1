param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [int]$DurationSeconds = 20,

  [Parameter(Mandatory = $false)]
  [int]$TcpWorkers = 12,

  [Parameter(Mandatory = $false)]
  [int]$UdpWorkers = 6,

  [Parameter(Mandatory = $false)]
  [double]$MaxFailureRate = 0.03,

  [Parameter(Mandatory = $false)]
  [double]$MinThroughputRps = 20.0,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host_soak_report.json"
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

function Wait-TcpPort([string]$endpointHost, [int]$port, [int]$timeoutMs) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $client = $null
    try {
      $client = [System.Net.Sockets.TcpClient]::new()
      $connect = $client.ConnectAsync($endpointHost, $port)
      if ($connect.Wait(250) -and $client.Connected) {
        $client.Dispose()
        return
      }
    }
    catch {
      # retry
    }
    finally {
      if ($null -ne $client) {
        $client.Dispose()
      }
    }
    Start-Sleep -Milliseconds 80
  }
  throw ("timeout waiting tcp endpoint {0}:{1}" -f $endpointHost, $port)
}

function Invoke-TcpCommand([string]$endpointHost, [int]$port, [string]$command) {
  $lastError = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $client.Connect($endpointHost, $port)
      $stream = $client.GetStream()
      $stream.ReadTimeout = 3000
      $stream.WriteTimeout = 3000
      $payload = [System.Text.Encoding]::UTF8.GetBytes($command + "`n")
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
    catch {
      $lastError = $_
      Start-Sleep -Milliseconds 120
    }
    finally {
      $client.Dispose()
    }
  }
  throw $lastError
}

function Invoke-UdpCommand([string]$endpointHost, [int]$port, [string]$command) {
  $udp = [System.Net.Sockets.UdpClient]::new()
  try {
    $udp.Client.ReceiveTimeout = 3000
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($command + "`n")
    [void]$udp.Send($bytes, $bytes.Length, $endpointHost, $port)
    $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
    $response = $udp.Receive([ref]$remote)
    return [System.Text.Encoding]::UTF8.GetString($response).Trim()
  }
  finally {
    $udp.Dispose()
  }
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

function Get-Int64PropertyOrDefault($obj, [string]$propertyName, [int64]$defaultValue) {
  if ($null -eq $obj) {
    return $defaultValue
  }
  $prop = $obj.PSObject.Properties[$propertyName]
  if ($null -eq $prop) {
    return $defaultValue
  }
  return [int64]$prop.Value
}

$tmpRoot = ".tmp/runtime_host_soak"
$endpointHost = "127.0.0.1"
$tcpPort = Get-FreeTcpPort
$udpPort = $tcpPort + 1
$dbPath = Join-Path $tmpRoot "runtime.sqlite"
$luaPath = Join-Path $tmpRoot "runtime.lua"
$stdoutLog = Join-Path $tmpRoot "server.stdout.log"
$stderrLog = Join-Path $tmpRoot "server.stderr.log"
$stressReportPath = Join-Path $tmpRoot "stress_report.json"
$serverPath = "scripts/runtime_host_server.py"
$stressPath = "scripts/runtime_host_stress.py"

if (-not (Test-Path $serverPath)) {
  throw "missing runtime host server script: $serverPath"
}
if (-not (Test-Path $stressPath)) {
  throw "missing runtime host stress script: $stressPath"
}

New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
"-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $luaPath -Encoding UTF8

$proc = $null
$report = $null

try {
  $serverArgs = @(
    $serverPath,
    "--host", $endpointHost,
    "--tcp-port", $tcpPort,
    "--udp-port", $udpPort,
    "--db-path", $dbPath,
    "--runtime-name", "soak",
    "--thread-count", 8,
    "--tick-interval-ms", 20,
    "--task-budget", 2048,
    "--lua-script-path", $luaPath
  )

  $proc = Start-Process -FilePath $PythonExe `
    -ArgumentList $serverArgs `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

  Start-Sleep -Milliseconds 200
  if ($proc.HasExited) {
    $stderr = if (Test-Path $stderrLog) { (Get-Content -Raw $stderrLog) } else { "" }
    throw ("runtime host exited early before readiness; exit={0}; stderr={1}" -f $proc.ExitCode, $stderr)
  }

  Wait-TcpPort -endpointHost $endpointHost -port $tcpPort -timeoutMs 15000
  Start-Sleep -Milliseconds 200

  & $PythonExe $stressPath `
    --host $endpointHost `
    --tcp-port $tcpPort `
    --udp-port $udpPort `
    --duration-s $DurationSeconds `
    --tcp-workers $TcpWorkers `
    --udp-workers $UdpWorkers `
    --timeout-ms 1200 `
    --output-path $stressReportPath
  if ($LASTEXITCODE -ne 0) {
    throw "runtime host stress failed"
  }

  if (-not (Test-Path $stressReportPath)) {
    throw "missing stress report: $stressReportPath"
  }

  $stress = Get-Content -Raw $stressReportPath | ConvertFrom-Json
  $stopReply = Invoke-UdpCommand -endpointHost $endpointHost -port $udpPort -command "__STOP__"

  $proc.WaitForExit(8000) | Out-Null
  if (-not $proc.HasExited) {
    $proc.Kill()
  }

  $overallFailureRate = [double]$stress.overall.failure_rate
  $overallThroughput = [double]$stress.overall.throughput_rps
  $tcpFailureRate = [double]$stress.tcp.failure_rate
  $udpFailureRate = [double]$stress.udp.failure_rate
  $metrics = $stress.metrics
  $runOk = [bool]$stress.run_ok
  $timerTickCount = Get-Int64PropertyOrDefault -obj $metrics -propertyName "timer_tick_count" -defaultValue -1
  $ioPollCount = Get-Int64PropertyOrDefault -obj $metrics -propertyName "io_poll_count" -defaultValue -1
  $errorCount = Get-Int64PropertyOrDefault -obj $metrics -propertyName "error_count" -defaultValue 2147483647
  $hasMetricsError = $null -ne $metrics.PSObject.Properties["metrics_fetch_error"]

  $pass = $runOk `
    -and ($stopReply -eq "__STOP_OK__") `
    -and (-not $hasMetricsError) `
    -and ($overallFailureRate -le $MaxFailureRate) `
    -and ($tcpFailureRate -le $MaxFailureRate) `
    -and ($udpFailureRate -le $MaxFailureRate) `
    -and ($overallThroughput -ge $MinThroughputRps) `
    -and ($timerTickCount -ge 5) `
    -and ($ioPollCount -ge 5) `
    -and ($errorCount -lt ([int64]([int64]$stress.overall.attempts / 2)))

  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = $pass
    host = $endpointHost
    tcp_port = $tcpPort
    udp_port = $udpPort
    duration_s = $DurationSeconds
    thresholds = [ordered]@{
      max_failure_rate = $MaxFailureRate
      min_throughput_rps = $MinThroughputRps
      min_tick_count = 5
      min_poll_count = 5
    }
    outcomes = [ordered]@{
      stop_reply = $stopReply
      overall_failure_rate = $overallFailureRate
      overall_throughput_rps = $overallThroughput
      tcp_failure_rate = $tcpFailureRate
      udp_failure_rate = $udpFailureRate
      metrics_fetch_error = if ($hasMetricsError) { [string]$metrics.metrics_fetch_error } else { "" }
      timer_tick_count = $timerTickCount
      io_poll_count = $ioPollCount
      error_count = $errorCount
    }
    stress_report = $stress
    logs = [ordered]@{
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
  throw "runtime host soak failed; report: $OutputPath"
}

Write-Output "PASS runtime host soak"
Write-Output ("REPORT={0}" -f (Resolve-Path $OutputPath).Path)
