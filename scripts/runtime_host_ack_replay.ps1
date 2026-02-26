param(
  [Parameter(Mandatory = $false)]
  [string]$InputPath = ".tmp/runtime_host/ack_replay_input.json",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/ack_replay_report.json",

  [Parameter(Mandatory = $false)]
  [int]$MaxInflight = 128
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-ParentDir([string]$path) {
  $parent = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
}

function New-BridgeState {
  return [ordered]@{
    bridge_online = $false
    next_sequence_id = 1
    inflight = 0
    emitted = 0
    ack_ok = 0
    ack_error = 0
    rejected = 0
    errors = 0
    last_error_code = 0
    last_opcode = 0
  }
}

function Test-ValidOpcode([int64]$opcode) {
  return $opcode -ge 1 -and $opcode -le 7
}

function New-DefaultEvents {
  return @(
    [ordered]@{ action = "open"; host_online = $true },
    [ordered]@{ action = "emit"; opcode = 1; endpoint_id = 1001; payload_bytes = 0; aux_code = 0 },
    [ordered]@{ action = "emit"; opcode = 2; endpoint_id = 1001; payload_bytes = 128; aux_code = 0 },
    [ordered]@{ action = "ack"; sequence_id = 1; ack_ok = $true; ack_error_code = 0 },
    [ordered]@{ action = "ack"; sequence_id = 2; ack_ok = $true; ack_error_code = 0 },
    [ordered]@{ action = "emit"; opcode = 3; endpoint_id = 1001; payload_bytes = 96; aux_code = 0 },
    [ordered]@{ action = "ack"; sequence_id = 3; ack_ok = $false; ack_error_code = 9107 },
    [ordered]@{ action = "close" }
  )
}

if ($MaxInflight -le 0) {
  throw "MaxInflight must be > 0"
}

Ensure-ParentDir $InputPath
Ensure-ParentDir $OutputPath

if (-not (Test-Path $InputPath)) {
  $defaults = New-DefaultEvents
  $defaults | ConvertTo-Json -Depth 6 | Set-Content -Path $InputPath -Encoding UTF8
}

$raw = Get-Content -Raw $InputPath
if ([string]::IsNullOrWhiteSpace($raw)) {
  throw "InputPath is empty: $InputPath"
}

$events = $raw | ConvertFrom-Json
if ($events -isnot [System.Array]) {
  $events = @($events)
}

$state = New-BridgeState
$inflightMap = @{}
$eventReports = @()

for ($i = 0; $i -lt $events.Count; $i++) {
  $e = $events[$i]
  $index = $i + 1
  $action = [string]$e.action
  $applied = $false
  $reason = 0
  $sequenceOut = 0

  if ($action -eq "open") {
    $hostOnline = [bool]$e.host_online
    if ($state.bridge_online) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9101
      $reason = 9101
    } elseif (-not $hostOnline) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9102
      $reason = 9102
    } else {
      $state.bridge_online = $true
      $applied = $true
    }
  } elseif ($action -eq "emit") {
    $opcode = [int64]$e.opcode
    $state.last_opcode = $opcode
    if (-not $state.bridge_online) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9103
      $reason = 9103
    } elseif (-not (Test-ValidOpcode $opcode)) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9104
      $reason = 9104
    } elseif ($state.inflight -ge $MaxInflight) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9105
      $reason = 9105
    } else {
      $sequenceOut = [int64]$state.next_sequence_id
      $inflightMap[[string]$sequenceOut] = $opcode
      $state.next_sequence_id = if ($sequenceOut -ge 2000000000) { 1 } else { $sequenceOut + 1 }
      $state.inflight++
      $state.emitted++
      $applied = $true
    }
  } elseif ($action -eq "ack") {
    $sequenceId = [int64]$e.sequence_id
    $ackOk = [bool]$e.ack_ok
    $ackErrorCode = [int64]$e.ack_error_code
    if (-not $state.bridge_online) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9103
      $reason = 9103
    } elseif ($sequenceId -le 0 -or -not $inflightMap.ContainsKey([string]$sequenceId)) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9106
      $reason = 9106
    } else {
      $inflightMap.Remove([string]$sequenceId) | Out-Null
      if ($state.inflight -gt 0) {
        $state.inflight--
      }
      if ($ackOk) {
        $state.ack_ok++
        $applied = $true
      } else {
        $state.ack_error++
        $state.errors++
        $state.last_error_code = $ackErrorCode
        $reason = 9107
      }
    }
  } elseif ($action -eq "close") {
    if (-not $state.bridge_online) {
      $state.rejected++
      $state.errors++
      $state.last_error_code = 9108
      $reason = 9108
    } else {
      $state.bridge_online = $false
      $state.inflight = 0
      $inflightMap = @{}
      $applied = $true
    }
  } else {
    $state.rejected++
    $state.errors++
    $state.last_error_code = 9199
    $reason = 9199
  }

  $eventReports += [ordered]@{
    index = $index
    action = $action
    applied = $applied
    reason_code = $reason
    sequence_id = $sequenceOut
    inflight_after = $state.inflight
    rejected_total = $state.rejected
    errors_total = $state.errors
  }
}

$report = [ordered]@{
  input_path = (Resolve-Path $InputPath).Path
  max_inflight = $MaxInflight
  totals = [ordered]@{
    emitted = $state.emitted
    ack_ok = $state.ack_ok
    ack_error = $state.ack_error
    rejected = $state.rejected
    errors = $state.errors
    inflight_final = $state.inflight
    bridge_online = $state.bridge_online
    last_error_code = $state.last_error_code
    last_opcode = $state.last_opcode
  }
  events = $eventReports
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output ("WROTE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)
