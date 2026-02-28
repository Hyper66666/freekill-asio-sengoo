param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe",

  [Parameter(Mandatory = $false)]
  [string]$EndpointHost = "127.0.0.1",

  [Parameter(Mandatory = $false)]
  [string]$FixturesPath = "scripts/fixtures/protobuf_rpc_regression_cases.json",

  [Parameter(Mandatory = $false)]
  [int]$ConnectTimeoutMs = 1200,

  [Parameter(Mandatory = $false)]
  [int]$ReadTimeoutMs = 2000,

  [Parameter(Mandatory = $false)]
  [int]$StartupWaitMs = 1400,

  [Parameter(Mandatory = $false)]
  [switch]$StartRuntime,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/protobuf_rpc_regression_native_report.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-AbsolutePath([string]$path, [string]$baseDir) {
  if ([System.IO.Path]::IsPathRooted($path)) {
    return [System.IO.Path]::GetFullPath($path)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $baseDir $path))
}

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function Convert-HexToBytes([string]$hexText) {
  $normalized = ([string]$hexText).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return [byte[]]@()
  }
  if (($normalized.Length % 2) -ne 0) {
    throw "hex text length must be even: $normalized"
  }
  $data = New-Object byte[] ($normalized.Length / 2)
  for ($i = 0; $i -lt $data.Length; $i++) {
    $data[$i] = [Convert]::ToByte($normalized.Substring($i * 2, 2), 16)
  }
  return $data
}

function Convert-BytesToHex([byte[]]$bytes) {
  if ($null -eq $bytes -or $bytes.Length -eq 0) {
    return ""
  }
  return [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
}

function Get-ByteDiff([byte[]]$expected, [byte[]]$actual) {
  $limit = [Math]::Min($expected.Length, $actual.Length)
  $firstMismatch = -1
  for ($i = 0; $i -lt $limit; $i++) {
    if ($expected[$i] -ne $actual[$i]) {
      $firstMismatch = $i
      break
    }
  }
  if ($firstMismatch -lt 0 -and $expected.Length -ne $actual.Length) {
    $firstMismatch = $limit
  }
  return [ordered]@{
    match = ($firstMismatch -lt 0)
    first_mismatch_offset = $firstMismatch
    expected_length = $expected.Length
    actual_length = $actual.Length
    expected_hex = (Convert-BytesToHex $expected)
    actual_hex = (Convert-BytesToHex $actual)
  }
}

function Find-ByteSubsequence([byte[]]$haystack, [byte[]]$needle) {
  if ($null -eq $needle -or $needle.Length -eq 0) {
    return [ordered]@{
      match = $true
      first_match_offset = 0
      needle_length = 0
      haystack_length = if ($null -eq $haystack) { 0 } else { $haystack.Length }
      needle_hex = ""
      haystack_hex = (Convert-BytesToHex $haystack)
    }
  }
  if ($null -eq $haystack -or $haystack.Length -lt $needle.Length) {
    return [ordered]@{
      match = $false
      first_match_offset = -1
      needle_length = $needle.Length
      haystack_length = if ($null -eq $haystack) { 0 } else { $haystack.Length }
      needle_hex = (Convert-BytesToHex $needle)
      haystack_hex = (Convert-BytesToHex $haystack)
    }
  }

  $maxOffset = $haystack.Length - $needle.Length
  for ($offset = 0; $offset -le $maxOffset; $offset++) {
    $ok = $true
    for ($i = 0; $i -lt $needle.Length; $i++) {
      if ($haystack[$offset + $i] -ne $needle[$i]) {
        $ok = $false
        break
      }
    }
    if ($ok) {
      return [ordered]@{
        match = $true
        first_match_offset = $offset
        needle_length = $needle.Length
        haystack_length = $haystack.Length
        needle_hex = (Convert-BytesToHex $needle)
        haystack_hex = (Convert-BytesToHex $haystack)
      }
    }
  }

  return [ordered]@{
    match = $false
    first_match_offset = -1
    needle_length = $needle.Length
    haystack_length = $haystack.Length
    needle_hex = (Convert-BytesToHex $needle)
    haystack_hex = (Convert-BytesToHex $haystack)
  }
}

function Decode-Varint([byte[]]$bytes, [int]$offset) {
  $value = [int64]0
  $shift = 0
  $index = $offset
  while ($index -lt $bytes.Length) {
    $b = [int]$bytes[$index]
    $value = $value -bor (([int64]($b -band 0x7F)) -shl $shift)
    $index++
    if (($b -band 0x80) -eq 0) {
      return [ordered]@{
        ok = $true
        value = $value
        next = $index
      }
    }
    $shift += 7
    if ($shift -gt 63) {
      break
    }
  }
  return [ordered]@{
    ok = $false
    value = [int64]0
    next = $offset
  }
}

function Parse-ProtobufFlat([byte[]]$bytes) {
  $index = 0
  $fields = @()
  while ($index -lt $bytes.Length) {
    $key = Decode-Varint $bytes $index
    if (-not [bool]$key.ok) {
      return [ordered]@{
        ok = $false
        error = ("invalid field key at offset {0}" -f $index)
        fields = @()
      }
    }
    $index = [int]$key.next
    $wireType = [int]($key.value -band 0x07)
    $fieldNo = [int]($key.value -shr 3)
    if ($fieldNo -le 0) {
      return [ordered]@{
        ok = $false
        error = ("invalid field number at offset {0}" -f $index)
        fields = @()
      }
    }

    if ($wireType -eq 0) {
      $val = Decode-Varint $bytes $index
      if (-not [bool]$val.ok) {
        return [ordered]@{
          ok = $false
          error = ("invalid varint field {0} at offset {1}" -f $fieldNo, $index)
          fields = @()
        }
      }
      $index = [int]$val.next
      $fields += [ordered]@{
        field = $fieldNo
        wire_type = $wireType
        value_i64 = [int64]$val.value
        value_hex = ""
        value_utf8 = ""
      }
      continue
    }

    if ($wireType -eq 2) {
      $lenResult = Decode-Varint $bytes $index
      if (-not [bool]$lenResult.ok) {
        return [ordered]@{
          ok = $false
          error = ("invalid length prefix field {0} at offset {1}" -f $fieldNo, $index)
          fields = @()
        }
      }
      $index = [int]$lenResult.next
      $len = [int]$lenResult.value
      if ($len -lt 0 -or ($index + $len) -gt $bytes.Length) {
        return [ordered]@{
          ok = $false
          error = ("invalid length-delimited range field {0} at offset {1}" -f $fieldNo, $index)
          fields = @()
        }
      }
      $chunk = New-Object byte[] $len
      if ($len -gt 0) {
        [Array]::Copy($bytes, $index, $chunk, 0, $len)
      }
      $index += $len
      $utf8Text = ""
      try {
        $utf8Text = [System.Text.Encoding]::UTF8.GetString($chunk)
      } catch {
        $utf8Text = ""
      }
      $fields += [ordered]@{
        field = $fieldNo
        wire_type = $wireType
        value_i64 = [int64]0
        value_hex = (Convert-BytesToHex $chunk)
        value_utf8 = $utf8Text
      }
      continue
    }

    return [ordered]@{
      ok = $false
      error = ("unsupported wire type {0} at field {1}" -f $wireType, $fieldNo)
      fields = @()
    }
  }

  return [ordered]@{
    ok = $true
    error = ""
    fields = $fields
  }
}

function Get-FirstField([object[]]$fields, [int]$fieldNo, [int]$wireType) {
  foreach ($f in $fields) {
    if ([int]$f.field -eq $fieldNo -and [int]$f.wire_type -eq $wireType) {
      return $f
    }
  }
  return $null
}

function Test-ProtobufSemantic([string]$mode, [byte[]]$requestBytes, [byte[]]$responseBytes) {
  $requestParsed = Parse-ProtobufFlat $requestBytes
  $responseParsed = Parse-ProtobufFlat $responseBytes
  if (-not [bool]$requestParsed.ok) {
    return [ordered]@{
      ok = $false
      reason = ("request parse failed: {0}" -f [string]$requestParsed.error)
      request = $requestParsed
      response = $responseParsed
    }
  }
  if (-not [bool]$responseParsed.ok) {
    return [ordered]@{
      ok = $false
      reason = ("response parse failed: {0}" -f [string]$responseParsed.error)
      request = $requestParsed
      response = $responseParsed
    }
  }

  $reqPayload = Get-FirstField @($requestParsed.fields) 1 2
  $reqSeq = Get-FirstField @($requestParsed.fields) 2 0
  $reqKeep = Get-FirstField @($requestParsed.fields) 3 0
  $respPayload = Get-FirstField @($responseParsed.fields) 1 2
  $respSeq = Get-FirstField @($responseParsed.fields) 2 0
  $respKeep = Get-FirstField @($responseParsed.fields) 3 0

  if ($null -eq $reqPayload -or $null -eq $reqSeq -or $null -eq $reqKeep) {
    return [ordered]@{
      ok = $false
      reason = "request semantic fields missing"
      request = $requestParsed
      response = $responseParsed
    }
  }
  if ($null -eq $respPayload -or $null -eq $respSeq -or $null -eq $respKeep) {
    return [ordered]@{
      ok = $false
      reason = "response semantic fields missing"
      request = $requestParsed
      response = $responseParsed
    }
  }

  $expectedPayload = [string]$reqPayload.value_utf8
  if ($mode -eq "upper_ping") {
    $expectedPayload = $expectedPayload.ToUpperInvariant()
  }
  $ok = ([string]$respPayload.value_utf8 -eq $expectedPayload) `
    -and ([int64]$respSeq.value_i64 -eq [int64]$reqSeq.value_i64) `
    -and ([int64]$respKeep.value_i64 -eq [int64]$reqKeep.value_i64)

  return [ordered]@{
    ok = $ok
    reason = if ($ok) { "semantic check passed" } else { "semantic fields mismatch" }
    request = $requestParsed
    response = $responseParsed
  }
}

function Try-StripExtensionSyncPrelude([System.Collections.Generic.List[byte]]$buffer) {
  if ($null -eq $buffer -or $buffer.Count -eq 0) {
    return [ordered]@{
      complete = $false
      stripped = $false
    }
  }

  $snapshot = $buffer.ToArray()
  if ($snapshot[0] -ne [byte][char]'{') {
    return [ordered]@{
      complete = $true
      stripped = $false
    }
  }

  $newline = [Array]::IndexOf($snapshot, [byte]10)
  if ($newline -lt 0) {
    return [ordered]@{
      complete = $false
      stripped = $false
    }
  }

  $lineBytes = New-Object byte[] ($newline + 1)
  [Array]::Copy($snapshot, 0, $lineBytes, 0, $newline + 1)
  $lineText = [System.Text.Encoding]::UTF8.GetString($lineBytes)
  if (-not $lineText.Contains('"event":"extension_sync"')) {
    return [ordered]@{
      complete = $true
      stripped = $false
    }
  }

  $buffer.Clear()
  for ($i = $newline + 1; $i -lt $snapshot.Length; $i++) {
    [void]$buffer.Add($snapshot[$i])
  }

  return [ordered]@{
    complete = $true
    stripped = $true
  }
}

function Invoke-TcpCase([string]$targetHost, [int]$port, [byte[]]$requestBytes, [int]$readBytes, [int]$readTimeoutMs) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connectTask = $client.ConnectAsync($targetHost, $port)
    if (-not $connectTask.Wait(1200)) {
      throw ("tcp connect timeout to {0}:{1}" -f $targetHost, $port)
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $readTimeoutMs
    $stream.WriteTimeout = $readTimeoutMs
    $stream.Write($requestBytes, 0, $requestBytes.Length)
    $stream.Flush()

    $buffer = [System.Collections.Generic.List[byte]]::new()
    $chunk = New-Object byte[] ([Math]::Max($readBytes, 512))
    $deadline = [DateTime]::UtcNow.AddMilliseconds($readTimeoutMs)
    $preludeResolved = $false
    while ((($buffer.Count -lt $readBytes) -or (-not $preludeResolved)) -and ([DateTime]::UtcNow -lt $deadline)) {
      if (-not $stream.DataAvailable) {
        Start-Sleep -Milliseconds 8
        continue
      }

      $read = $stream.Read($chunk, 0, $chunk.Length)
      if ($read -le 0) {
        break
      }
      for ($i = 0; $i -lt $read; $i++) {
        [void]$buffer.Add($chunk[$i])
      }

      if (-not $preludeResolved) {
        $probe = Try-StripExtensionSyncPrelude -buffer $buffer
        if ([bool]$probe.complete) {
          $preludeResolved = $true
        } elseif ($buffer.Count -ge ([Math]::Max($readBytes, 1024))) {
          $preludeResolved = $true
        }
      }
    }

    if (-not $preludeResolved) {
      [void](Try-StripExtensionSyncPrelude -buffer $buffer)
    }

    $response = $buffer.ToArray()
    if ($response.Length -gt $readBytes) {
      $truncated = New-Object byte[] $readBytes
      [Array]::Copy($response, 0, $truncated, 0, $readBytes)
      return $truncated
    }
    return $response
  } finally {
    $client.Dispose()
  }
}

function Invoke-UdpCase([string]$targetHost, [int]$port, [byte[]]$requestBytes, [int]$readTimeoutMs) {
  $lastError = $null
  for ($attempt = 0; $attempt -lt 4; $attempt++) {
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
      $udp.Client.ReceiveTimeout = $readTimeoutMs
      [void]$udp.Send($requestBytes, $requestBytes.Length, $targetHost, $port)
      $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
      return $udp.Receive([ref]$remote)
    } catch {
      $lastError = $_
      Start-Sleep -Milliseconds 120
    } finally {
      $udp.Dispose()
    }
  }
  throw $lastError
}

function Wait-TcpPort([string]$targetHost, [int]$port, [int]$timeoutMs) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
      $task = $client.ConnectAsync($targetHost, $port)
      if ($task.Wait(250) -and $client.Connected) {
        return $true
      }
    } catch {
      # retry
    } finally {
      $client.Dispose()
    }
    Start-Sleep -Milliseconds 80
  }
  return $false
}

function Get-OptionalString([object]$obj, [string]$name, [string]$fallback) {
  if ($null -eq $obj) {
    return $fallback
  }
  $prop = $obj.PSObject.Properties[$name]
  if ($null -eq $prop) {
    return $fallback
  }
  $value = $prop.Value
  if ($null -eq $value) {
    return $fallback
  }
  return [string]$value
}

function Get-OptionalInt([object]$obj, [string]$name, [int]$fallback) {
  $raw = Get-OptionalString $obj $name ""
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $fallback
  }
  $parsed = 0
  if ([int]::TryParse($raw, [ref]$parsed)) {
    return $parsed
  }
  return $fallback
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedFixturesPath = Resolve-AbsolutePath -path $FixturesPath -baseDir $repoRoot
$resolvedBinaryPath = Resolve-AbsolutePath -path $BinaryPath -baseDir $repoRoot

if (-not (Test-Path $resolvedFixturesPath)) {
  throw "fixtures file not found: $resolvedFixturesPath"
}

$rawFixture = Get-Content -Raw -Path $resolvedFixturesPath
if ([string]::IsNullOrWhiteSpace($rawFixture)) {
  throw "fixtures file is empty: $resolvedFixturesPath"
}
$fixture = $rawFixture | ConvertFrom-Json
$cases = @($fixture.cases)
if ($cases.Count -eq 0) {
  throw "fixtures contains no cases: $resolvedFixturesPath"
}

$runtimeProc = $null
$runtimeStarted = $false
$runtimeBootOk = $true
$runtimeBootError = ""
$hadAuthPreludeEnv = $false
$previousAuthPreludeEnv = $null

try {
  if ([bool]$StartRuntime) {
    if (-not (Test-Path $resolvedBinaryPath)) {
      throw "native runtime binary not found: $resolvedBinaryPath"
    }
    $hadAuthPreludeEnv = Test-Path Env:SENGOO_AUTH_SEND_NETWORK_DELAY
    if ($hadAuthPreludeEnv) {
      $previousAuthPreludeEnv = [string]$env:SENGOO_AUTH_SEND_NETWORK_DELAY
    } else {
      $env:SENGOO_AUTH_SEND_NETWORK_DELAY = "0"
    }
    $runtimeProc = Start-Process -FilePath $resolvedBinaryPath -PassThru
    Start-Sleep -Milliseconds $StartupWaitMs
    $runtimeProc.Refresh()
    if ($runtimeProc.HasExited) {
      $runtimeBootOk = $false
      $runtimeBootError = ("runtime exited early with code {0}" -f [int]$runtimeProc.ExitCode)
    } else {
      $runtimeStarted = $true
    }
  }

  $caseResults = @()
  $failedCount = 0

  foreach ($case in $cases) {
    $caseId = Get-OptionalString $case "id" ""
    $transport = Get-OptionalString $case "transport" ""
    $kind = Get-OptionalString $case "kind" "protobuf"
    $port = [int](Get-OptionalString $case "port" "0")
    $semanticMode = Get-OptionalString $case "semantic_mode" ""
    $expectedHex = Get-OptionalString $case "expected_response_hex" ""
    $requestHex = Get-OptionalString $case "request_hex" ""
    $requestUtf8 = Get-OptionalString $case "request_utf8" ""
    $expectedUtf8 = Get-OptionalString $case "expected_response_utf8" ""
    $matchMode = (Get-OptionalString $case "match_mode" "exact").ToLowerInvariant()
    $expectedContainsHex = Get-OptionalString $case "expected_response_contains_hex" ""
    $expectedContainsUtf8 = Get-OptionalString $case "expected_response_contains_utf8" ""
    $responseCaptureBytes = Get-OptionalInt $case "response_capture_bytes" 0

    $requestBytes = [byte[]]@()
    $expectedBytes = [byte[]]@()
    $containsBytes = [byte[]]@()
    if ($kind -eq "rpc_text") {
      $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestUtf8)
      if ([string]::IsNullOrWhiteSpace($expectedUtf8)) {
        $expectedUtf8 = $requestUtf8
      }
      $expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($expectedUtf8)
      if ([string]::IsNullOrWhiteSpace($expectedContainsUtf8)) {
        $expectedContainsUtf8 = $expectedUtf8
      }
      $containsBytes = [System.Text.Encoding]::UTF8.GetBytes($expectedContainsUtf8)
    } else {
      $requestBytes = Convert-HexToBytes $requestHex
      if ([string]::IsNullOrWhiteSpace($expectedHex)) {
        $expectedBytes = $requestBytes
      } else {
        $expectedBytes = Convert-HexToBytes $expectedHex
      }
      if ([string]::IsNullOrWhiteSpace($expectedContainsHex)) {
        $expectedContainsHex = $expectedHex
      }
      if ([string]::IsNullOrWhiteSpace($expectedContainsHex)) {
        $containsBytes = $expectedBytes
      } else {
        $containsBytes = Convert-HexToBytes $expectedContainsHex
      }
    }

    if ($matchMode -ne "exact" -and $matchMode -ne "contains") {
      throw ("unsupported match_mode: {0} in case {1}" -f $matchMode, $caseId)
    }

    $responseReadBytes = $expectedBytes.Length
    if ($responseReadBytes -le 0) {
      $responseReadBytes = [Math]::Max(512, $containsBytes.Length)
    }
    if ($matchMode -eq "contains") {
      if ($responseCaptureBytes -le 0) {
        $responseCaptureBytes = [Math]::Max(2048, [Math]::Max($responseReadBytes, $containsBytes.Length))
      }
      $responseReadBytes = $responseCaptureBytes
    }

    $casePass = $false
    $reasonCode = 0
    $reasonText = "ok"
    $responseBytes = [byte[]]@()
    $semantic = $null
    $byteDiff = $null

    try {
      if ($runtimeStarted -and $transport -eq "tcp" -and -not (Wait-TcpPort -targetHost $EndpointHost -port $port -timeoutMs $ConnectTimeoutMs)) {
        throw ("port not ready: {0}:{1}" -f $EndpointHost, $port)
      }

      if ($transport -eq "tcp") {
        $responseBytes = Invoke-TcpCase -targetHost $EndpointHost -port $port -requestBytes $requestBytes -readBytes $responseReadBytes -readTimeoutMs $ReadTimeoutMs
      } elseif ($transport -eq "udp") {
        $responseBytes = Invoke-UdpCase -targetHost $EndpointHost -port $port -requestBytes $requestBytes -readTimeoutMs $ReadTimeoutMs
      } else {
        throw ("unsupported transport: {0}" -f $transport)
      }

      if ($matchMode -eq "contains") {
        $byteDiff = Find-ByteSubsequence -haystack $responseBytes -needle $containsBytes
        if (-not [bool]$byteDiff.match) {
          $reasonCode = 9705
          $reasonText = "response missing expected subsequence"
        } else {
          $casePass = $true
        }
      } else {
        $byteDiff = Get-ByteDiff -expected $expectedBytes -actual $responseBytes
        if (-not [bool]$byteDiff.match) {
          $reasonCode = 9703
          $reasonText = "byte mismatch"
        } else {
          if ($kind -eq "protobuf") {
            if ([string]::IsNullOrWhiteSpace($semanticMode)) {
              $semanticMode = "echo_ping"
            }
            $semantic = Test-ProtobufSemantic -mode $semanticMode -requestBytes $requestBytes -responseBytes $responseBytes
            if (-not [bool]$semantic.ok) {
              $reasonCode = 9704
              $reasonText = [string]$semantic.reason
            } else {
              $casePass = $true
            }
          } else {
            $casePass = $true
          }
        }
      }
    } catch {
      $reasonCode = 9702
      $reasonText = $_.Exception.Message
      $casePass = $false
    }

    if (-not $casePass) {
      $failedCount++
    }
    $caseResults += [ordered]@{
      id = $caseId
      kind = $kind
      transport = $transport
      host = $EndpointHost
      port = $port
      pass = $casePass
      reason_code = $reasonCode
      reason = $reasonText
      match_mode = $matchMode
      request_hex = (Convert-BytesToHex $requestBytes)
      response_hex = (Convert-BytesToHex $responseBytes)
      expected_response_hex = (Convert-BytesToHex $expectedBytes)
      expected_response_contains_hex = (Convert-BytesToHex $containsBytes)
      byte_diff = $byteDiff
      semantic = $semantic
    }
  }

  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = ($failedCount -eq 0) -and $runtimeBootOk
    runtime = [ordered]@{
      start_runtime = [bool]$StartRuntime
      started = $runtimeStarted
      boot_ok = $runtimeBootOk
      boot_error = $runtimeBootError
      binary_path = if (Test-Path $resolvedBinaryPath) { (Resolve-Path $resolvedBinaryPath).Path } else { $resolvedBinaryPath }
    }
    fixture_path = $resolvedFixturesPath
    summary = [ordered]@{
      total = $caseResults.Count
      failed = $failedCount
      passed = ($caseResults.Count - $failedCount)
    }
    cases = $caseResults
  }

  Ensure-ParentDir $OutputPath
  $report | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputPath -Encoding UTF8

  Write-Output ("PROTOBUF_RPC_REGRESSION_PASS={0}" -f [bool]$report.pass)
  Write-Output ("PROTOBUF_RPC_REGRESSION_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

  if (-not [bool]$report.pass) {
    exit 1
  }
} finally {
  if ($null -ne $runtimeProc) {
    try {
      $runtimeProc.Refresh()
      if (-not $runtimeProc.HasExited) {
        Stop-Process -Id $runtimeProc.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {
      # best effort cleanup
    }
  }
  if ($hadAuthPreludeEnv) {
    $env:SENGOO_AUTH_SEND_NETWORK_DELAY = $previousAuthPreludeEnv
  } else {
    Remove-Item Env:SENGOO_AUTH_SEND_NETWORK_DELAY -ErrorAction SilentlyContinue
  }
}
