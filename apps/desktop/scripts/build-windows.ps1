$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$appsRoot = Split-Path -Parent $projectRoot
$helperSource = Join-Path $appsRoot "hook-helper\ZCodeStatusHook.cs"
$helperOutput = Join-Path $projectRoot "assets\hook\ZCodeStatusHook.exe"
$csharpCompiler = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$outputRoot = Join-Path $projectRoot "artifacts\windows"
$temporaryOutput = Join-Path $env:TEMP "zcode-status-light-build-$PID"
$builder = Join-Path $projectRoot "node_modules\.bin\electron-builder.cmd"
$electronCache = Join-Path $env:LOCALAPPDATA "electron\Cache"
$builderCache = Join-Path $env:LOCALAPPDATA "electron-builder\Cache"

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

  $installer = Get-ChildItem -LiteralPath $temporaryOutput -File -Filter "*.exe" |
    Where-Object { $_.Name -notlike "*__uninstaller*" } |
    Select-Object -First 1
  if (-not $installer) {
    throw "Electron Builder did not create an NSIS installer."
  }

  Copy-Item -LiteralPath $installer.FullName -Destination (Join-Path $outputRoot $installer.Name) -Force
  $blockMap = "$($installer.FullName).blockmap"
  if (Test-Path -LiteralPath $blockMap) {
    Copy-Item -LiteralPath $blockMap -Destination (Join-Path $outputRoot "$($installer.Name).blockmap") -Force
  }

  Write-Host "Created installer: $(Join-Path $outputRoot $installer.Name)"
} finally {
  Pop-Location -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $temporaryOutput -Recurse -Force -ErrorAction SilentlyContinue
}
