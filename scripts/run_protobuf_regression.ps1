param(
  [Parameter(Mandatory = $false)]
  [string]$EndpointHost = "127.0.0.1",

  [Parameter(Mandatory = $true)]
  [int]$Port,

  [Parameter(Mandatory = $false)]
  [string]$RequestHex = "0a03666f6f10071801",

  [Parameter(Mandatory = $false)]
  [string]$ExpectedResponseHex = "0a03666f6f10071801",

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
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

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$nativeRunner = Resolve-AbsolutePath -path "scripts/run_protobuf_rpc_regression_native.ps1" -baseDir $repoRoot

if (-not (Test-Path $nativeRunner)) {
  throw "missing native protobuf/rpc regression runner: $nativeRunner"
}

$tmpFixture = Resolve-AbsolutePath -path ".tmp/runtime_host/protobuf_regression_single_case.json" -baseDir $repoRoot
Ensure-ParentDir $tmpFixture
$fixture = [ordered]@{
  schema_version = 1
  description = "single-case protobuf regression wrapper"
  cases = @(
    [ordered]@{
      id = "single-protobuf-regression"
      kind = "protobuf"
      transport = "tcp"
      port = $Port
      request_hex = $RequestHex
      expected_response_hex = $ExpectedResponseHex
      semantic_mode = "echo_ping"
    }
  )
}
$fixture | ConvertTo-Json -Depth 8 | Set-Content -Path $tmpFixture -Encoding UTF8

& powershell -NoProfile -ExecutionPolicy Bypass -File $nativeRunner `
  -EndpointHost $EndpointHost `
  -FixturesPath $tmpFixture `
  -OutputPath $OutputPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "protobuf regression failed for ${EndpointHost}:$Port (report: $OutputPath)"
}

Write-Output ("PASS protobuf regression -> {0}" -f (Resolve-Path $OutputPath).Path)
