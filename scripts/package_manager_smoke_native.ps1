param(
  [Parameter(Mandatory = $false)]
  [string]$PackageManagerScriptPath = "scripts/package_manager_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$PackageCompatibilityScriptPath = "scripts/check_package_compatibility_native.ps1",

  [Parameter(Mandatory = $false)]
  [string]$OutputPath = ".tmp/runtime_host/package_manager_smoke_native.json"
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

function New-LocalGitPackageRepo([string]$rootDir, [string]$packageName) {
  $repoDir = Join-Path $rootDir $packageName
  New-Item -ItemType Directory -Path $repoDir -Force | Out-Null
  & git -C $repoDir init | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "failed to init local git repo: $repoDir"
  }
  Set-Content -Path (Join-Path $repoDir "README.md") -Encoding UTF8 -Value ("# " + $packageName)
  & git -C $repoDir add README.md | Out-Null
  & git -C $repoDir -c user.name="package-smoke" -c user.email="package-smoke@example.invalid" commit -m "init $packageName" | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "failed to commit local git repo: $repoDir"
  }
  return [pscustomobject]@{
    path = $repoDir
    url = ([System.Uri]::new($repoDir)).AbsoluteUri
  }
}

function Invoke-PackageCommand(
  [string]$scriptPath,
  [string]$packagesRoot,
  [string]$commandName,
  [string]$reportPath,
  [int]$expectedExitCode,
  [string]$name,
  [string]$url
) {
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass",
    "-File", $scriptPath,
    "-Command", $commandName,
    "-PackagesRoot", $packagesRoot,
    "-OutputPath", $reportPath,
    "-AsJson"
  )
  if (-not [string]::IsNullOrWhiteSpace($name)) {
    $args += @("-Name", $name)
  }
  if (-not [string]::IsNullOrWhiteSpace($url)) {
    $args += @("-Url", $url)
  }

  $raw = & powershell @args
  $exitCode = [int]$LASTEXITCODE
  if ($exitCode -ne $expectedExitCode) {
    throw ("command {0} expected exit {1}, actual {2}" -f $commandName, $expectedExitCode, $exitCode)
  }
  $jsonText = ($raw -join [Environment]::NewLine).Trim()
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw ("command {0} returned empty json output" -f $commandName)
  }
  return $jsonText | ConvertFrom-Json
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
  (Resolve-Path $PSScriptRoot).Path
} else {
  (Get-Location).Path
}
$repoRoot = Resolve-AbsolutePath -path ".." -baseDir $scriptDir
$resolvedPackageManagerScriptPath = Resolve-AbsolutePath -path $PackageManagerScriptPath -baseDir $repoRoot
$resolvedPackageCompatibilityScriptPath = Resolve-AbsolutePath -path $PackageCompatibilityScriptPath -baseDir $repoRoot

if (-not (Test-Path $resolvedPackageManagerScriptPath)) {
  throw "package manager script not found: $resolvedPackageManagerScriptPath"
}
if (-not (Test-Path $resolvedPackageCompatibilityScriptPath)) {
  throw "package compatibility script not found: $resolvedPackageCompatibilityScriptPath"
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) {
  throw "git command not found"
}

$tmpRoot = Resolve-AbsolutePath -path ".tmp/package_manager_smoke_native" -baseDir $repoRoot
if (Test-Path $tmpRoot) {
  Remove-Item -Recurse -Force $tmpRoot
}
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$remoteRoot = Join-Path $tmpRoot "remote"
$packagesRoot = Join-Path $tmpRoot "packages"
$reportRoot = Join-Path $tmpRoot "reports"
New-Item -ItemType Directory -Path $remoteRoot -Force | Out-Null
New-Item -ItemType Directory -Path $reportRoot -Force | Out-Null

$coreRepo = New-LocalGitPackageRepo -rootDir $remoteRoot -packageName "freekill-core"
$extRepo = New-LocalGitPackageRepo -rootDir $remoteRoot -packageName "ext-sample"

$reports = [ordered]@{}
$reports.init = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "init" -reportPath (Join-Path $reportRoot "01-init.json") -expectedExitCode 0 -name "" -url ""
$reports.install_core = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "install" -reportPath (Join-Path $reportRoot "02-install-core.json") -expectedExitCode 0 -name "" -url $coreRepo.url

$coreEntryPath = Join-Path $packagesRoot "freekill-core/lua/server/rpc/entry.lua"
New-Item -ItemType Directory -Path (Split-Path -Parent $coreEntryPath) -Force | Out-Null
Set-Content -Path $coreEntryPath -Encoding UTF8 -Value "return { smoke = true }"

$reports.syncpkgs = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "syncpkgs" -reportPath (Join-Path $reportRoot "03-syncpkgs.json") -expectedExitCode 0 -name "" -url ""
$reports.pkgs = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "pkgs" -reportPath (Join-Path $reportRoot "04-pkgs.json") -expectedExitCode 0 -name "" -url ""
$reports.disable_core = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "disable" -reportPath (Join-Path $reportRoot "05-disable-core.json") -expectedExitCode 1 -name "freekill-core" -url ""
$reports.install_ext = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "install" -reportPath (Join-Path $reportRoot "06-install-ext.json") -expectedExitCode 0 -name "" -url $extRepo.url
$reports.disable_ext = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "disable" -reportPath (Join-Path $reportRoot "07-disable-ext.json") -expectedExitCode 0 -name "ext-sample" -url ""
$reports.enable_ext = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "enable" -reportPath (Join-Path $reportRoot "08-enable-ext.json") -expectedExitCode 0 -name "ext-sample" -url ""
$reports.upgrade_ext = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "upgrade" -reportPath (Join-Path $reportRoot "09-upgrade-ext.json") -expectedExitCode 1 -name "ext-sample" -url ""
$reports.remove_ext = Invoke-PackageCommand -scriptPath $resolvedPackageManagerScriptPath -packagesRoot $packagesRoot -commandName "remove" -reportPath (Join-Path $reportRoot "10-remove-ext.json") -expectedExitCode 0 -name "ext-sample" -url ""

$compatReportPath = Join-Path $reportRoot "11-compat.json"
& powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedPackageCompatibilityScriptPath -PackagesRoot $packagesRoot -OutputPath $compatReportPath | Out-Null
$compatExitCode = [int]$LASTEXITCODE
if ($compatExitCode -ne 0) {
  throw ("package compatibility script failed with exit code {0}" -f $compatExitCode)
}
$compatReport = Get-Content -Raw $compatReportPath | ConvertFrom-Json

$pkgsHasCore = $false
$pkgs = @($reports.pkgs.details.packages)
foreach ($pkg in $pkgs) {
  if ([string]$pkg.name -eq "freekill-core") {
    $pkgsHasCore = $true
    break
  }
}

$checks = [ordered]@{
  disable_core_reason_code_ok = ([int]$reports.disable_core.reason_code -eq 9301)
  upgrade_partial_failure_reason_code_ok = ([int]$reports.upgrade_ext.reason_code -eq 9302)
  pkgs_contains_freekill_core = $pkgsHasCore
  compatibility_pass = [bool]$compatReport.pass
}
$pass = [bool]$checks.disable_core_reason_code_ok `
  -and [bool]$checks.upgrade_partial_failure_reason_code_ok `
  -and [bool]$checks.pkgs_contains_freekill_core `
  -and [bool]$checks.compatibility_pass

$summary = [ordered]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  pass = $pass
  package_manager_script = $resolvedPackageManagerScriptPath
  package_compatibility_script = $resolvedPackageCompatibilityScriptPath
  packages_root = $packagesRoot
  checks = $checks
  compatibility_report = $compatReport
  command_reports = $reports
}

Ensure-ParentDir $OutputPath
$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Output ("PACKAGE_SMOKE_PASS={0}" -f $pass)
Write-Output ("PACKAGE_SMOKE_REPORT={0}" -f (Resolve-Path $OutputPath).Path)

if (-not $pass) {
  exit 1
}
