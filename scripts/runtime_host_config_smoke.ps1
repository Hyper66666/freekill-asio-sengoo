param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host_config_smoke_report.json"
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
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $client.Connect($endpointHost, $port)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 2500
    $stream.WriteTimeout = 2500
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
  finally {
    $client.Dispose()
  }
}

function Invoke-UdpCommand([string]$endpointHost, [int]$port, [string]$command) {
  $udp = [System.Net.Sockets.UdpClient]::new()
  try {
    $udp.Client.ReceiveTimeout = 2500
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

$endpointHost = "127.0.0.1"
$serverPath = "scripts/runtime_host_server.py"
if (-not (Test-Path $serverPath)) {
  throw "missing runtime host server script: $serverPath"
}

$tmpRoot = ".tmp/runtime_host_config_smoke"
$tcpPort = Get-FreeTcpPort
$udpPort = $tcpPort + 1
$dbPath = Join-Path $tmpRoot "runtime.sqlite"
$luaPath = Join-Path $tmpRoot "runtime.lua"
$configPath = Join-Path $tmpRoot "runtime_config.json"
$stdoutLog = Join-Path $tmpRoot "server.stdout.log"
$stderrLog = Join-Path $tmpRoot "server.stderr.log"
$runtimeName = "cfg-smoke"

New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
"-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $luaPath -Encoding UTF8

$cfg = [ordered]@{
  host = $endpointHost
  tcp_port = $tcpPort
  udp_port = $udpPort
  runtime_name = $runtimeName
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
try {
  $args = @($serverPath, "--config-json", $configPath)
  $proc = Start-Process -FilePath $PythonExe `
    -ArgumentList $args `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

  Wait-TcpPort -endpointHost $endpointHost -port $tcpPort -timeoutMs 7000
  Start-Sleep -Milliseconds 200

  $tcpReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M1_CONN_PING"
  $udpReply = Invoke-UdpCommand -endpointHost $endpointHost -port $udpPort -command "M1_UDP_PING"
  $metricsRaw = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "__METRICS__"
  $stopReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "__STOP__"

  $proc.WaitForExit(5000) | Out-Null
  if (-not $proc.HasExited) {
    $proc.Kill()
  }

  $metrics = $metricsRaw | ConvertFrom-Json
  $pass = ($tcpReply -eq "M1_CONN_PONG") `
    -and ($udpReply -eq "M1_UDP_PONG") `
    -and ($stopReply -eq "__STOP_OK__") `
    -and ([string]$metrics.runtime_name -eq $runtimeName) `
    -and ([int64]$metrics.tcp_port -eq $tcpPort) `
    -and ([int64]$metrics.udp_port -eq $udpPort)

  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = $pass
    tcp_port = $tcpPort
    udp_port = $udpPort
    runtime_name = $runtimeName
    tcp_reply = $tcpReply
    udp_reply = $udpReply
    stop_reply = $stopReply
    metrics = $metrics
    config_path = (Resolve-Path $configPath).Path
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
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

if (-not [bool]$report.pass) {
  throw "runtime host config smoke failed; report: $OutputPath"
}

Write-Output "PASS runtime host config smoke"
Write-Output ("REPORT={0}" -f (Resolve-Path $OutputPath).Path)
