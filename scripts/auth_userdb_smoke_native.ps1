param(
  [Parameter(Mandatory = $false)]
  [string]$BinaryPath = "release/native/windows-x64/bin/freekill-asio-sengoo-runtime.exe",

  [Parameter(Mandatory = $false)]
  [int]$StartupWaitMs = 900,

  [Parameter(Mandatory = $false)]
  [int]$ReadTimeoutMs = 1600,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/auth_userdb_smoke_native.json"
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

function Encode-CborLength([int]$major, [int]$len) {
  if ($len -lt 24) {
    return [byte[]]@([byte](($major -shl 5) -bor $len))
  }
  if ($len -le 255) {
    return [byte[]]@([byte](($major -shl 5) -bor 24), [byte]$len)
  }
  return [byte[]]@(
    [byte](($major -shl 5) -bor 25),
    [byte](($len -shr 8) -band 0xFF),
    [byte]($len -band 0xFF)
  )
}

function Join-ByteArrays {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Parts
  )
  $list = [System.Collections.Generic.List[byte]]::new()
  foreach ($part in $Parts) {
    if ($null -eq $part) {
      continue
    }
    [byte[]]$bytes = [byte[]]@()
    if ($part -is [byte[]]) {
      $bytes = $part
    } elseif ($part -is [byte]) {
      $bytes = [byte[]]@([byte]$part)
    } else {
      $bytes = [byte[]]$part
    }
    for ($i = 0; $i -lt $bytes.Length; $i++) {
      [void]$list.Add($bytes[$i])
    }
  }
  return $list.ToArray()
}

function Encode-CborUtf8([string]$text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $head = Encode-CborLength -major 3 -len $bytes.Length
  return (Join-ByteArrays -Parts @($head, $bytes))
}

function Encode-CborBytes([byte[]]$bytes) {
  $head = Encode-CborLength -major 2 -len $bytes.Length
  return (Join-ByteArrays -Parts @($head, $bytes))
}

function Get-Sha256Hex([string]$text) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $digest = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($digest).Replace("-", "").ToLowerInvariant())
}

function Encode-SetupPacket([string]$name, [string]$password, [string]$md5, [string]$version, [string]$uuid) {
  $payload = Join-ByteArrays -Parts @(
    [byte[]]@([byte]0x85),
    (Encode-CborUtf8 $name),
    (Encode-CborUtf8 $password),
    (Encode-CborUtf8 $md5),
    (Encode-CborUtf8 $version),
    (Encode-CborUtf8 $uuid)
  )

  $packetHead = [byte[]]@(
    [byte]0x84,
    [byte]0x21,
    [byte]0x19, [byte]0x04, [byte]0x12
  )
  return (Join-ByteArrays -Parts @(
    $packetHead,
    (Encode-CborBytes ([System.Text.Encoding]::UTF8.GetBytes("Setup"))),
    (Encode-CborBytes $payload)
  ))
}

function Invoke-SetupFlow([string]$targetHost, [int]$port, [byte[]]$packet, [int]$readTimeoutMs) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.ConnectAsync($targetHost, $port)
    if (-not $connect.Wait(1200)) {
      throw "tcp connect timeout to $targetHost`:$port"
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $readTimeoutMs
    $stream.WriteTimeout = $readTimeoutMs

    Start-Sleep -Milliseconds 120
    $drain = New-Object byte[] 2048
    while ($stream.DataAvailable) {
      [void]$stream.Read($drain, 0, $drain.Length)
    }

    $stream.Write($packet, 0, $packet.Length)
    $stream.Flush()

    $acc = [System.Collections.Generic.List[byte]]::new()
    $buf = New-Object byte[] 4096
    $deadline = [DateTime]::UtcNow.AddMilliseconds($readTimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
      if (-not $stream.DataAvailable) {
        Start-Sleep -Milliseconds 20
        continue
      }
      $read = $stream.Read($buf, 0, $buf.Length)
      if ($read -le 0) {
        break
      }
      for ($i = 0; $i -lt $read; $i++) {
        [void]$acc.Add($buf[$i])
      }
    }

    $bytes = $acc.ToArray()
    return [ordered]@{
      bytes = $bytes
      text = [System.Text.Encoding]::UTF8.GetString($bytes)
      hex = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
    }
  } finally {
    $client.Dispose()
  }
}

function Read-SessionBytes([System.Net.Sockets.NetworkStream]$stream, [int]$readTimeoutMs) {
  $acc = [System.Collections.Generic.List[byte]]::new()
  $buf = New-Object byte[] 4096
  $deadline = [DateTime]::UtcNow.AddMilliseconds($readTimeoutMs)
  while ([DateTime]::UtcNow -lt $deadline) {
    if (-not $stream.DataAvailable) {
      Start-Sleep -Milliseconds 20
      continue
    }
    $read = $stream.Read($buf, 0, $buf.Length)
    if ($read -le 0) {
      break
    }
    for ($i = 0; $i -lt $read; $i++) {
      [void]$acc.Add($buf[$i])
    }
  }
  $bytes = $acc.ToArray()
  return [ordered]@{
    bytes = $bytes
    text = [System.Text.Encoding]::UTF8.GetString($bytes)
    hex = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
  }
}

function Open-SetupSession([string]$targetHost, [int]$port, [byte[]]$packet, [int]$readTimeoutMs) {
  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.ConnectAsync($targetHost, $port)
    if (-not $connect.Wait(1200)) {
      throw "tcp connect timeout to $targetHost`:$port"
    }
    $stream = $client.GetStream()
    $stream.ReadTimeout = $readTimeoutMs
    $stream.WriteTimeout = $readTimeoutMs

    Start-Sleep -Milliseconds 120
    $drain = New-Object byte[] 2048
    while ($stream.DataAvailable) {
      [void]$stream.Read($drain, 0, $drain.Length)
    }

    $stream.Write($packet, 0, $packet.Length)
    $stream.Flush()
    $initial = Read-SessionBytes -stream $stream -readTimeoutMs $readTimeoutMs

    return [ordered]@{
      client = $client
      stream = $stream
      initial = $initial
    }
  } catch {
    $client.Dispose()
    throw
  }
}

function Invoke-CaseWithRuntime([string]$resolvedBinary, [int]$startupWaitMs, [scriptblock]$caseAction) {
  $proc = $null
  try {
    $proc = Start-Process -FilePath $resolvedBinary -PassThru
    Start-Sleep -Milliseconds $startupWaitMs
    $proc.Refresh()
    if ($proc.HasExited) {
      throw ("runtime exited early with code {0}" -f [int]$proc.ExitCode)
    }
    return & $caseAction
  } finally {
    if ($null -ne $proc) {
      try {
        $proc.Refresh()
        if (-not $proc.HasExited) {
          Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
      } catch {
      }
    }
  }
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedBinary = Resolve-AbsolutePath -path $BinaryPath -baseDir $repoRoot
if (-not (Test-Path $resolvedBinary)) {
  throw "native runtime binary not found: $resolvedBinary"
}

$tmpDir = Join-Path $repoRoot ".tmp/runtime_host"
if (-not (Test-Path $tmpDir)) {
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
}
$userFile = Join-Path $tmpDir "auth_userdb_smoke.users.tsv"
$bindingFile = Join-Path $tmpDir "auth_userdb_smoke.bindings.tsv"
$whitelistFile = Join-Path $tmpDir "auth_userdb_smoke.whitelist.txt"
$banWordsFile = Join-Path $tmpDir "auth_userdb_smoke.ban_words.txt"
if (Test-Path $userFile) { Remove-Item $userFile -Force }
if (Test-Path $bindingFile) { Remove-Item $bindingFile -Force }
if (Test-Path $whitelistFile) { Remove-Item $whitelistFile -Force }
if (Test-Path $banWordsFile) { Remove-Item $banWordsFile -Force }

$envBackup = @{}
$envKeys = @(
  "SENGOO_AUTH_SEND_NETWORK_DELAY",
  "SENGOO_AUTH_ENFORCE_MD5",
  "SENGOO_AUTH_USERDB_ENABLE",
  "SENGOO_AUTH_USER_FILE",
  "SENGOO_AUTH_UUID_BINDING_FILE",
  "SENGOO_AUTH_USERDB_AUTO_REGISTER",
  "SENGOO_AUTH_MAX_PLAYERS_PER_DEVICE",
  "SENGOO_AUTH_WHITELIST_FILE",
  "SENGOO_BAN_WORDS_FILE"
)
foreach ($k in $envKeys) {
  if (Test-Path ("Env:" + $k)) {
    $envBackup[$k] = (Get-Item ("Env:" + $k)).Value
  }
}

try {
  $env:SENGOO_AUTH_SEND_NETWORK_DELAY = "0"
  $env:SENGOO_AUTH_ENFORCE_MD5 = "0"
  $env:SENGOO_AUTH_USERDB_ENABLE = "1"
  $env:SENGOO_AUTH_USER_FILE = $userFile
  $env:SENGOO_AUTH_UUID_BINDING_FILE = $bindingFile
  $env:SENGOO_AUTH_USERDB_AUTO_REGISTER = "0"
  $env:SENGOO_AUTH_MAX_PLAYERS_PER_DEVICE = "1"
  Remove-Item Env:SENGOO_AUTH_WHITELIST_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:SENGOO_BAN_WORDS_FILE -ErrorAction SilentlyContinue

  Set-Content -Path $userFile -Encoding ascii -Value "42|alice|secret|guanyu|0|0"
  $case1 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $resp = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "secret" "md5" "0.5.19" "u1") -readTimeoutMs $ReadTimeoutMs
    [ordered]@{
      pass = $resp.text.Contains("Setup") -and $resp.text.Contains("SetServerSettings") -and -not $resp.text.Contains("ErrorDlg")
      setup = $resp.text.Contains("Setup")
      settings = $resp.text.Contains("SetServerSettings")
      no_error = -not $resp.text.Contains("ErrorDlg")
      player_id_42 = $resp.hex.Contains("182a")
    }
  }

  $case2 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $resp = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "wrong" "md5" "0.5.19" "u1") -readTimeoutMs $ReadTimeoutMs
    [ordered]@{
      pass = $resp.text.Contains("ErrorDlg") -and $resp.text.Contains("username or password error") -and -not $resp.text.Contains("Setup")
      error = $resp.text.Contains("ErrorDlg")
      password_reject = $resp.text.Contains("username or password error")
      no_setup = -not $resp.text.Contains("Setup")
    }
  }

  if (Test-Path $userFile) { Remove-Item $userFile -Force }
  if (Test-Path $bindingFile) { Remove-Item $bindingFile -Force }
  $env:SENGOO_AUTH_USERDB_AUTO_REGISTER = "1"
  $env:SENGOO_AUTH_MAX_PLAYERS_PER_DEVICE = "1"
  $case3 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $resp1 = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "pass1" "md5" "0.5.19" "u1") -readTimeoutMs $ReadTimeoutMs
    $resp2 = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "bob" "pass2" "md5" "0.5.19" "u1") -readTimeoutMs $ReadTimeoutMs
    $storedLine = ""
    if (Test-Path $userFile) {
      $storedLine = [string](Get-Content -Path $userFile -TotalCount 1 -ErrorAction SilentlyContinue)
    }
    $hashFormat = $storedLine -match "^[0-9]+\|[^|]+\|[0-9a-f]{64}\|[^|]*\|0\|0\|[0-9a-f]{8}$"
    [ordered]@{
      pass = $resp1.text.Contains("Setup") -and $resp2.text.Contains("cannot register more new users on this device") -and $hashFormat
      first_registered = $resp1.text.Contains("Setup")
      second_limited = $resp2.text.Contains("cannot register more new users on this device")
      user_file_exists = Test-Path $userFile
      binding_file_exists = Test-Path $bindingFile
      password_hash_format = $hashFormat
      stored_user_line = $storedLine
    }
  }

  Set-Content -Path $userFile -Encoding ascii -Value "42|alice|secret|guanyu|0|0"
  $case4 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $session1 = $null
    try {
      $session1 = Open-SetupSession -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "secret" "md5" "0.5.19" "u1") -readTimeoutMs $ReadTimeoutMs
      Start-Sleep -Milliseconds 120
      $resp2 = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "secret" "md5" "0.5.19" "u2") -readTimeoutMs $ReadTimeoutMs
      $kicked = Read-SessionBytes -stream $session1.stream -readTimeoutMs $ReadTimeoutMs
      [ordered]@{
        pass = $session1.initial.text.Contains("Setup") -and $resp2.text.Contains("Setup") -and $kicked.text.Contains("others logged in again with this name")
        first_setup = $session1.initial.text.Contains("Setup")
        second_setup = $resp2.text.Contains("Setup")
        kicked_message = $kicked.text.Contains("others logged in again with this name")
      }
    } finally {
      if ($null -ne $session1 -and $null -ne $session1.client) {
        $session1.client.Dispose()
      }
    }
  }

  Set-Content -Path $userFile -Encoding ascii -Value "42|alice|secret|guanyu|0|0"
  Set-Content -Path $whitelistFile -Encoding ascii -Value @("alice")
  Set-Content -Path $banWordsFile -Encoding ascii -Value @("bad")
  $env:SENGOO_AUTH_WHITELIST_FILE = $whitelistFile
  $env:SENGOO_BAN_WORDS_FILE = $banWordsFile
  $case5 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $respWhitelist = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "charlie" "secret" "md5" "0.5.19" "u3") -readTimeoutMs $ReadTimeoutMs
    $respBanWord = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "badwolf" "secret" "md5" "0.5.19" "u4") -readTimeoutMs $ReadTimeoutMs
    [ordered]@{
      pass = $respWhitelist.text.Contains("user name not in whitelist") -and $respBanWord.text.Contains("invalid user name")
      whitelist_reject = $respWhitelist.text.Contains("user name not in whitelist")
      ban_word_reject = $respBanWord.text.Contains("invalid user name")
    }
  }
  Remove-Item Env:SENGOO_AUTH_WHITELIST_FILE -ErrorAction SilentlyContinue
  Remove-Item Env:SENGOO_BAN_WORDS_FILE -ErrorAction SilentlyContinue

  $salt6 = "1a2b3c4d"
  $hash6 = Get-Sha256Hex ("secret" + $salt6)
  Set-Content -Path $userFile -Encoding ascii -Value ("42|alice|{0}|guanyu|0|0|{1}" -f $hash6, $salt6)
  $case6 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $resp = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "secret" "md5" "0.5.19" "u5") -readTimeoutMs $ReadTimeoutMs
    [ordered]@{
      pass = $resp.text.Contains("Setup") -and -not $resp.text.Contains("ErrorDlg")
      setup = $resp.text.Contains("Setup")
      no_error = -not $resp.text.Contains("ErrorDlg")
    }
  }

  $expiredBanEpoch = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 120)
  Set-Content -Path $userFile -Encoding ascii -Value ("42|alice|secret|guanyu|1|{0}" -f $expiredBanEpoch)
  $case7 = Invoke-CaseWithRuntime -resolvedBinary $resolvedBinary -startupWaitMs $StartupWaitMs -caseAction {
    $resp = Invoke-SetupFlow -targetHost "127.0.0.1" -port 9527 -packet (Encode-SetupPacket "alice" "secret" "md5" "0.5.19" "u6") -readTimeoutMs $ReadTimeoutMs
    $storedLine = ""
    if (Test-Path $userFile) {
      $storedLine = [string](Get-Content -Path $userFile -TotalCount 1 -ErrorAction SilentlyContinue)
    }
    $unbannedPersisted = $storedLine -match "^[0-9]+\|[^|]+\|[^|]+\|[^|]*\|0\|0(?:\|[0-9a-fA-F]+)?$"
    [ordered]@{
      pass = $resp.text.Contains("Setup") -and $unbannedPersisted
      setup = $resp.text.Contains("Setup")
      unban_persisted = $unbannedPersisted
      stored_user_line = $storedLine
    }
  }

  $overallPass = [bool]$case1.pass -and [bool]$case2.pass -and [bool]$case3.pass -and [bool]$case4.pass -and [bool]$case5.pass -and [bool]$case6.pass -and [bool]$case7.pass
  $report = [ordered]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    pass = $overallPass
    binary_path = $resolvedBinary
    cases = [ordered]@{
      correct_password = $case1
      wrong_password = $case2
      auto_register_limit = $case3
      duplicate_login_kicks_old = $case4
      username_policy = $case5
      salted_sha256_password = $case6
      expired_tempban_autoclear = $case7
    }
  }

  Ensure-ParentDir $OutputPath
  $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
  Write-Output ("AUTH_USERDB_SMOKE_PASS={0}" -f [bool]$report.pass)
  Write-Output ("AUTH_USERDB_SMOKE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

  if (-not [bool]$report.pass) {
    exit 1
  }
} finally {
  foreach ($k in $envKeys) {
    if ($envBackup.ContainsKey($k)) {
      Set-Item -Path ("Env:" + $k) -Value ([string]$envBackup[$k])
    } else {
      Remove-Item -Path ("Env:" + $k) -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path $userFile) { Remove-Item $userFile -Force }
  if (Test-Path $bindingFile) { Remove-Item $bindingFile -Force }
  if (Test-Path $whitelistFile) { Remove-Item $whitelistFile -Force }
  if (Test-Path $banWordsFile) { Remove-Item $banWordsFile -Force }
}
