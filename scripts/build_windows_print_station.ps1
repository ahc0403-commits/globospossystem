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

function Find-VisualCppRuntimeDirectory {
  $requiredRuntimeFiles = @(
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
  )
  $candidateDirectories = [System.Collections.Generic.List[string]]::new()

  if (-not [string]::IsNullOrWhiteSpace($env:VCToolsRedistDir)) {
    $candidateDirectories.Add(
      (Join-Path $env:VCToolsRedistDir "x64\Microsoft.VC143.CRT")
    )
  }

  $vswherePath = Join-Path ${env:ProgramFiles(x86)} `
    "Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path -LiteralPath $vswherePath) {
    $installationPaths = @(
      & $vswherePath -products * -requires `
        Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    )
    if ($LASTEXITCODE -ne 0) {
      throw "vswhere failed while locating the Visual C++ runtime."
    }

    foreach ($installationPath in $installationPaths) {
      $redistRoot = Join-Path $installationPath "VC\Redist\MSVC"
      if (-not (Test-Path -LiteralPath $redistRoot)) {
        continue
      }

      $runtimeDirectories = Get-ChildItem -LiteralPath $redistRoot `
        -Directory -Recurse -Filter "Microsoft.VC*.CRT" |
        Where-Object { $_.Parent.Name -eq "x64" } |
        Sort-Object FullName -Descending
      foreach ($runtimeDirectory in $runtimeDirectories) {
        $candidateDirectories.Add($runtimeDirectory.FullName)
      }
    }
  }

  foreach ($candidateDirectory in $candidateDirectories) {
    $hasEveryRuntimeFile = $true
    foreach ($runtimeFile in $requiredRuntimeFiles) {
      if (-not (Test-Path -LiteralPath (
          Join-Path $candidateDirectory $runtimeFile
        ))) {
        $hasEveryRuntimeFile = $false
        break
      }
    }
    if ($hasEveryRuntimeFile) {
      return $candidateDirectory
    }
  }

  throw "Microsoft Visual C++ x64 runtime files were not found."
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

  # Flutter's Windows runner and native plugins use the dynamic MSVC runtime.
  # Bundle it app-locally so the POS starts on a clean Windows installation.
  $visualCppRuntimeDirectory = Find-VisualCppRuntimeDirectory
  $visualCppRuntimeFiles = @(
    "msvcp140.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll"
  )
  foreach ($runtimeFile in $visualCppRuntimeFiles) {
    Copy-Item -LiteralPath (
      Join-Path $visualCppRuntimeDirectory $runtimeFile
    ) -Destination $releaseDirectory -Force
    $bundledRuntimeFile = Join-Path $releaseDirectory $runtimeFile
    if (-not (Test-Path -LiteralPath $bundledRuntimeFile)) {
      throw "Required Visual C++ runtime was not bundled: $runtimeFile"
    }
  }

  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  Compress-Archive -Path (Join-Path $releaseDirectory "*") -DestinationPath $archivePath -Force
  Write-Output "Windows print station package: $archivePath"
} finally {
  if (Test-Path -LiteralPath $defineFile) {
    Remove-Item -LiteralPath $defineFile -Force
  }
}
