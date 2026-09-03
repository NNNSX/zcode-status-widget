$ErrorActionPreference = "Stop"

$desktopRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent (Split-Path -Parent $desktopRoot)
$packagePath = Join-Path $desktopRoot "package.json"
$windowsArtifacts = Join-Path $desktopRoot "artifacts\windows"

if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
  throw "Electron package.json is missing: $packagePath"
}
$package = Get-Content -LiteralPath $packagePath -Raw | ConvertFrom-Json
$version = [string]$package.version
$productName = [string]$package.build.productName
if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($productName)) {
  throw "Electron package.json must define version and build.productName."
}

$installerName = "$productName Setup $version.exe"
$installerPath = Join-Path $windowsArtifacts $installerName
$blockmapPath = "$installerPath.blockmap"
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
  throw "Current Electron installer is missing: $installerPath"
}
if (-not (Test-Path -LiteralPath $blockmapPath -PathType Leaf)) {
  throw "Current Electron installer blockmap is missing: $blockmapPath"
}

$releaseRoot = Join-Path $workspaceRoot "artifacts\release-v$version"
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null
$releaseInstaller = Join-Path $releaseRoot $installerName
$releaseBlockmap = Join-Path $releaseRoot (Split-Path -Leaf $blockmapPath)
Copy-Item -LiteralPath $installerPath -Destination $releaseInstaller -Force
Copy-Item -LiteralPath $blockmapPath -Destination $releaseBlockmap -Force

$checksums = @(
  (Get-FileHash -LiteralPath $releaseInstaller -Algorithm SHA256),
  (Get-FileHash -LiteralPath $releaseBlockmap -Algorithm SHA256)
)
$checksumLines = $checksums | ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))" }
Set-Content -LiteralPath (Join-Path $releaseRoot "SHA256SUMS.txt") -Value $checksumLines -Encoding utf8
Set-Content -LiteralPath (Join-Path $releaseRoot "release-title.txt") -Value "ZCode Status Light v$version" -Encoding utf8
$releaseNotes = @(
  "# ZCode Status Light v$version"
  ""
  "Electron Windows x64 prerelease. The installer is unsigned and Windows SmartScreen may show an unknown publisher warning."
  ""
  "Verify the installer and .blockmap with SHA256SUMS.txt before running setup."
)
Set-Content -LiteralPath (Join-Path $releaseRoot "RELEASE_NOTES.md") -Value $releaseNotes -Encoding utf8

Write-Host "Prepared Electron release directory: $releaseRoot"
Write-Host "Installer: $releaseInstaller"
Write-Host "Blockmap: $releaseBlockmap"
