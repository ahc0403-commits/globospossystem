param(
  [string]$ArtifactDirectory = "artifacts"
)

$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    throw "$FilePath exited with code $exitCode."
  }
}

if ([string]::IsNullOrWhiteSpace($env:SUPABASE_URL)) {
  throw "SUPABASE_URL is required."
}
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_ANON_KEY)) {
  throw "SUPABASE_ANON_KEY is required. Never use the service-role key in the client build."
}

$defineFile = [System.IO.Path]::GetTempFileName()
$artifactRoot = Join-Path (Get-Location) $ArtifactDirectory
$releaseDirectory = Join-Path (Get-Location) "build\windows\x64\runner\Release"
$archivePath = Join-Path $artifactRoot "globos_print_station_windows_x64.zip"

try {
  @{
    SUPABASE_URL = $env:SUPABASE_URL
    SUPABASE_ANON_KEY = $env:SUPABASE_ANON_KEY
  } | ConvertTo-Json | Set-Content -LiteralPath $defineFile -Encoding utf8

  Invoke-NativeCommand -FilePath "flutter" -Arguments @("pub", "get")
  Invoke-NativeCommand -FilePath "dart" -Arguments @(
    "analyze",
    "--fatal-infos"
  )
  Invoke-NativeCommand -FilePath "flutter" -Arguments @(
    "test",
    "test/print_routing_contract_test.dart",
    "test/windows_print_station_build_contract_test.dart",
    "test/cashier_receipt_print_contract_test.dart",
    "test/receipt_builder_contract_test.dart",
    "test/wifi_printer_service_test.dart"
  )
  Invoke-NativeCommand -FilePath "flutter" -Arguments @(
    "build",
    "windows",
    "--release",
    "--dart-define-from-file=$defineFile"
  )

  $executable = Join-Path $releaseDirectory "globos_print_station.exe"
  if (-not (Test-Path -LiteralPath $executable)) {
    throw "Windows executable was not created at $executable"
  }

  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  Compress-Archive -Path (Join-Path $releaseDirectory "*") -DestinationPath $archivePath -Force
  Write-Output "Windows print station package: $archivePath"
} finally {
  if (Test-Path -LiteralPath $defineFile) {
    Remove-Item -LiteralPath $defineFile -Force
  }
}
