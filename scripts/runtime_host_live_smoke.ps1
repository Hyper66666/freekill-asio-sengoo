param(
  [Parameter(Mandatory = $false)]
  [string]$PythonExe = "python",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host_live_smoke_report.json"
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
    Start-Sleep -Milliseconds 60
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
      $stream.ReadTimeout = 2000
      $stream.WriteTimeout = 2000
      $payload = [System.Text.Encoding]::UTF8.GetBytes($command + "`n")
      $stream.Write($payload, 0, $payload.Length)
      $stream.Flush()

      $bytes = New-Object 'System.Collections.Generic.List[byte]'
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
      Start-Sleep -Milliseconds 100
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
    $udp.Client.ReceiveTimeout = 2000
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

function Invoke-TcpBinaryRoundtrip(
  [string]$endpointHost,
  [int]$port,
  [string]$requestHex,
  [int]$expectedResponseBytes
) {
  if (($requestHex.Length % 2) -ne 0) {
    throw "requestHex must have even length"
  }
  $requestBytes = New-Object byte[] ($requestHex.Length / 2)
  for ($i = 0; $i -lt $requestBytes.Length; $i++) {
    $requestBytes[$i] = [Convert]::ToByte($requestHex.Substring($i * 2, 2), 16)
  }
  $lastError = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $client.Connect($endpointHost, $port)
      $stream = $client.GetStream()
      $stream.ReadTimeout = 2000
      $stream.WriteTimeout = 2000
      $stream.Write($requestBytes, 0, $requestBytes.Length)
      $stream.Flush()

      $buffer = New-Object byte[] $expectedResponseBytes
      $offset = 0
      while ($offset -lt $expectedResponseBytes) {
        $read = $stream.Read($buffer, $offset, $expectedResponseBytes - $offset)
        if ($read -le 0) {
          break
        }
        $offset += $read
      }
      if ($offset -ne $expectedResponseBytes) {
        return ""
      }
      return [System.BitConverter]::ToString($buffer).Replace("-", "").ToLowerInvariant()
    }
    catch {
      $lastError = $_
      Start-Sleep -Milliseconds 100
    }
    finally {
      $client.Dispose()
    }
  }
  throw $lastError
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
  }
}

$tcpPort = Get-FreeTcpPort
$udpPort = $tcpPort + 1
$endpointHost = "127.0.0.1"
$tmpRoot = ".tmp/runtime_host_live_smoke"
$dbPath = Join-Path $tmpRoot "runtime.sqlite"
$luaScriptPath = Join-Path $tmpRoot "runtime.lua"
$stdoutLog = Join-Path $tmpRoot "server.stdout.log"
$stderrLog = Join-Path $tmpRoot "server.stderr.log"
$serverPath = "scripts/runtime_host_server.py"

if (-not (Test-Path $serverPath)) {
  throw "missing server script: $serverPath"
}

New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
"-- VERSION:v1`nfunction runtime_hello()`n  return `"v1`"`nend`n" | Set-Content -Path $luaScriptPath -Encoding UTF8
$proc = $null
$report = $null

try {
  $args = @(
    $serverPath,
    "--host", $endpointHost,
    "--tcp-port", $tcpPort,
    "--udp-port", $udpPort,
    "--db-path", $dbPath,
    "--lua-script-path", $luaScriptPath,
    "--runtime-name", "smoke"
  )

  $proc = Start-Process -FilePath $PythonExe `
    -ArgumentList $args `
    -PassThru `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog

  Wait-TcpPort -endpointHost $endpointHost -port $tcpPort -timeoutMs 6000
  Start-Sleep -Milliseconds 200

  $tcpReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M1_CONN_PING"
  $udpReply = Invoke-UdpCommand -endpointHost $endpointHost -port $udpPort -command "M1_UDP_PING"
  $registerReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M3_REGISTER_FUNC:runtime_custom"
  $luaBefore = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M3_LUA_HELLO"
  $luaAsyncReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M3_LUA_HELLO_ASYNC"
  $hotReloadReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M3_HOT_RELOAD"
  $luaAfter = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M3_LUA_HELLO"
  $saveReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_SAVE_STATE:smoke-state"
  $loadReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_LOAD_STATE"
  $deleteReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_DELETE_STATE"
  $loadAfterDeleteReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_LOAD_STATE"
  $dbHealthReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_DB_HEALTH"
  $routeReply1 = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_ROUTE_THREAD:room-42"
  $routeReply2 = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M4_ROUTE_THREAD:room-42"
  $flowReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M5_FLOW_ROOM"
  $stabilityReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "M6_STABILITY"
  $protobufReplyHex = Invoke-TcpBinaryRoundtrip `
    -endpointHost $endpointHost `
    -port $tcpPort `
    -requestHex "0a03666f6f10071801" `
    -expectedResponseBytes 9
  Start-Sleep -Milliseconds 120
  $metricsRaw = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "__METRICS__"
  $stopReply = Invoke-TcpCommand -endpointHost $endpointHost -port $tcpPort -command "__STOP__"

  $proc.WaitForExit(5000) | Out-Null
  if (-not $proc.HasExited) {
    $proc.Kill()
  }

  $metrics = $metricsRaw | ConvertFrom-Json
  $luaVersionChanged = ($luaBefore -ne $luaAfter) -and ($luaBefore -like "M3_LUA_ACK:v*") -and ($luaAfter -like "M3_LUA_ACK:v*")
  $pass = ($tcpReply -eq "M1_CONN_PONG") `
    -and ($udpReply -eq "M1_UDP_PONG") `
    -and ($registerReply -eq "M3_REGISTER_OK:runtime_custom") `
    -and ($luaAsyncReply -like "M3_LUA_ASYNC_ACK:v*") `
    -and ($hotReloadReply -eq "M3_HOT_RELOAD_OK") `
    -and $luaVersionChanged `
    -and ($saveReply -eq "M4_SAVE_OK:smoke-state") `
    -and ($loadReply -eq "M4_LOAD_OK:smoke-state") `
    -and ($deleteReply -eq "M4_DELETE_OK") `
    -and ($loadAfterDeleteReply -eq "M4_LOAD_OK:unset") `
    -and ($dbHealthReply -eq "M4_DB_HEALTHY") `
    -and ($routeReply1 -eq $routeReply2) `
    -and ($routeReply1 -like "M4_ROUTE_OK:thread-*") `
    -and ($flowReply -eq "M5_FLOW_OK") `
    -and ($stabilityReply -eq "M6_OK") `
    -and ($protobufReplyHex -eq "0a03464f4f10071801") `
    -and ($stopReply -eq "__STOP_OK__") `
    -and ([int64]$metrics.accepted_connections -ge 1) `
    -and ([int64]$metrics.udp_rx_datagram_count -ge 1) `
    -and ([int64]$metrics.protobuf_request_count -ge 1) `
    -and ([int64]$metrics.codec_frame_parse_count -ge 1) `
    -and ([int64]$metrics.codec_frame_build_count -ge 1) `
    -and ([int64]$metrics.ffi_registered_function_count -ge 2) `
    -and ([int64]$metrics.ffi_sync_call_count -ge 2) `
    -and ([int64]$metrics.ffi_async_call_count -ge 1) `
    -and ([int64]$metrics.ffi_callback_dispatch_count -ge 1) `
    -and ([int64]$metrics.db_transaction_begin_count -ge 1) `
    -and ([int64]$metrics.db_commit_count -ge 1) `
    -and ([int64]$metrics.save_state_count -ge 1) `
    -and ([int64]$metrics.route_lookup_count -ge 2) `
    -and ([int64]$metrics.lua_hot_reload_count -ge 1) `
    -and ([int64]$metrics.timer_tick_count -ge 1)

  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = $pass
    tcp_port = $tcpPort
    udp_port = $udpPort
    tcp_reply = $tcpReply
    udp_reply = $udpReply
    register_reply = $registerReply
    lua_before = $luaBefore
    lua_async_reply = $luaAsyncReply
    hot_reload_reply = $hotReloadReply
    lua_after = $luaAfter
    save_reply = $saveReply
    load_reply = $loadReply
    delete_reply = $deleteReply
    load_after_delete_reply = $loadAfterDeleteReply
    db_health_reply = $dbHealthReply
    route_reply_1 = $routeReply1
    route_reply_2 = $routeReply2
    flow_reply = $flowReply
    stability_reply = $stabilityReply
    protobuf_reply_hex = $protobufReplyHex
    stop_reply = $stopReply
    metrics = $metrics
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
  throw "runtime host live smoke failed; report: $OutputPath"
}

Write-Output "PASS runtime host live smoke"
Write-Output ("REPORT={0}" -f (Resolve-Path $OutputPath).Path)
