$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$appsRoot = Split-Path -Parent $projectRoot
$helperSource = Join-Path $appsRoot "hook-helper\ZCodeStatusHook.cs"
$helperOutput = Join-Path $projectRoot "assets\hook\ZCodeStatusHook.exe"
$csharpCompiler = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$outputRoot = Join-Path $projectRoot "artifacts\windows"
$temporaryOutput = Join-Path $env:TEMP "zcode-status-light-build-$([guid]::NewGuid().ToString('N'))"
$builder = Join-Path $projectRoot "node_modules\.bin\electron-builder.cmd"
$electronCache = Join-Path $env:LOCALAPPDATA "electron\Cache"
$builderCache = Join-Path $env:LOCALAPPDATA "electron-builder\Cache"

# This package is intentionally unsigned; avoid probing for a certificate and downloading winCodeSign.
$env:CSC_IDENTITY_AUTO_DISCOVERY = "false"

if (Test-Path -LiteralPath $electronCache) {
  $env:ELECTRON_CACHE = $electronCache
}
if (Test-Path -LiteralPath $builderCache) {
  $env:ELECTRON_BUILDER_CACHE = $builderCache
  if (-not $env:ELECTRON_BUILDER_NSIS_DIR) {
    $cachedNsis = Get-ChildItem -LiteralPath (Join-Path $builderCache "nsis-3.0.4.1") -Directory -Filter "nsis-3.0.4.1-*" -ErrorAction SilentlyContinue |
      Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName "Bin\makensis.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName "elevate.exe") -PathType Leaf)
      } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($cachedNsis) {
      $env:ELECTRON_BUILDER_NSIS_DIR = $cachedNsis.FullName
    }
  }
  if (-not $env:ELECTRON_BUILDER_NSIS_RESOURCES_DIR) {
    $cachedNsisResources = Get-ChildItem -LiteralPath (Join-Path $builderCache "nsis-resources-3.4.1") -Directory -Filter "nsis-resources-3.4.1-*" -ErrorAction SilentlyContinue |
      Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "plugins") -PathType Container } |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($cachedNsisResources) {
      $env:ELECTRON_BUILDER_NSIS_RESOURCES_DIR = $cachedNsisResources.FullName
    }
  }
}

New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
if (Test-Path -LiteralPath $temporaryOutput) {
  Remove-Item -LiteralPath $temporaryOutput -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $temporaryOutput | Out-Null

try {
  Push-Location $projectRoot
  if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
    throw "Native Hook Helper source is missing: $helperSource"
  }
  if (-not (Test-Path -LiteralPath $csharpCompiler -PathType Leaf)) {
    throw "Windows .NET Framework C# compiler is missing: $csharpCompiler"
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $helperOutput) | Out-Null
  & $csharpCompiler /nologo /target:exe "/out:$helperOutput" /reference:System.Web.dll $helperSource
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helperOutput -PathType Leaf)) {
    throw "Native Hook Helper build failed with exit code $LASTEXITCODE."
  }

  & npm.cmd run build
  if ($LASTEXITCODE -ne 0) {
    throw "Desktop production build failed with exit code $LASTEXITCODE."
  }

  & $builder --win nsis --x64 "--config.directories.output=$temporaryOutput"
  if ($LASTEXITCODE -ne 0) {
    throw "Electron Builder failed with exit code $LASTEXITCODE."
  }

  $package = Get-Content -LiteralPath (Join-Path $projectRoot "package.json") -Raw | ConvertFrom-Json
  $expectedInstallerName = "$($package.build.productName) Setup $($package.version).exe"
  $installers = @(Get-ChildItem -LiteralPath $temporaryOutput -File -Filter "*.exe" |
    Where-Object { $_.Name -eq $expectedInstallerName })
  if ($installers.Count -ne 1) {
    throw "Expected exactly one installer named '$expectedInstallerName', found $($installers.Count)."
  }
  $installer = $installers[0]

  Copy-Item -LiteralPath $installer.FullName -Destination (Join-Path $outputRoot $installer.Name) -Force
  $blockMap = "$($installer.FullName).blockmap"
  if (-not (Test-Path -LiteralPath $blockMap -PathType Leaf)) {
    throw "Electron Builder did not create the installer blockmap: $blockMap"
  }
  Copy-Item -LiteralPath $blockMap -Destination (Join-Path $outputRoot "$($installer.Name).blockmap") -Force

  Write-Host "Created installer: $(Join-Path $outputRoot $installer.Name)"
} finally {
  Pop-Location -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temporaryOutput -Recurse -Force -ErrorAction SilentlyContinue
}
