param(
  [Parameter(Mandatory = $false)]
  [string]$EndpointHost = "127.0.0.1",

  [Parameter(Mandatory = $true)]
  [int]$Port,

  [Parameter(Mandatory = $false)]
  [string]$RequestHex = "0a03666f6f10071801",

  [Parameter(Mandatory = $false)]
  [string]$ExpectedResponseHex = "0a03464f4f10071801",

  [Parameter(Mandatory = $true)]
  [string]$OutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$runner = "scripts/protobuf_regression.py"
if (-not (Test-Path $runner)) {
  throw "Missing protobuf regression runner: $runner"
}

& python $runner `
  --host $EndpointHost `
  --port $Port `
  --request-hex $RequestHex `
  --expected-response-hex $ExpectedResponseHex `
  --output-path $OutputPath
if ($LASTEXITCODE -ne 0) {
  throw "protobuf regression failed for ${EndpointHost}:$Port (report: $OutputPath)"
}

Write-Output "PASS protobuf regression -> $OutputPath"
