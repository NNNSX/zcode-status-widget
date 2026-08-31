[CmdletBinding()]
param(
    [string]$Version,
    [string]$BinaryPath,
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
if (-not $BinaryPath) { $BinaryPath = Join-Path $ProjectRoot "dist\ZCodeStatusLight.exe" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "release" }
$VersionSource = Get-Content -LiteralPath (Join-Path $ProjectRoot "version.py") -Raw -Encoding utf8
if (-not $Version -and $VersionSource -match 'VERSION\s*=\s*["'']([^"'']+)["'']') {
    $Version = $matches[1]
}
if (-not $Version) { throw "Could not read the version. Pass -Version explicitly." }
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') {
    throw "Version must use semantic versioning: $Version"
}

$BinaryPath = [System.IO.Path]::GetFullPath($BinaryPath)
if (-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)) { throw "EXE was not found: $BinaryPath" }
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$PackageName = "ZCodeStatusLight-v$Version-windows-x64"
$Stage = Join-Path $OutputRoot "$PackageName-stage"
$ZipPath = Join-Path $OutputRoot "$PackageName.zip"
Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$ZipPath.sha256" -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

$Files = @(
    @{ Source = $BinaryPath; Destination = "ZCodeStatusLight.exe" },
    @{ Source = (Join-Path $ProjectRoot "hook_handler.py"); Destination = "hook_handler.py" },
    @{ Source = (Join-Path $ProjectRoot "install.ps1"); Destination = "install.ps1" },
    @{ Source = (Join-Path $ProjectRoot "uninstall.ps1"); Destination = "uninstall.ps1" },
    @{ Source = (Join-Path $ProjectRoot "README.md"); Destination = "README.md" },
    @{ Source = (Join-Path $ProjectRoot "LICENSE"); Destination = "LICENSE" },
    @{ Source = (Join-Path $ProjectRoot "CHANGELOG.md"); Destination = "CHANGELOG.md" },
    @{ Source = (Join-Path $ProjectRoot "THIRD_PARTY_NOTICES.md"); Destination = "THIRD_PARTY_NOTICES.md" },
    @{ Source = (Join-Path $ProjectRoot "version.py"); Destination = "version.py" },
    @{ Source = (Join-Path $ProjectRoot "docs\zcode-hooks.example.json"); Destination = "docs\zcode-hooks.example.json" }
)
foreach ($File in $Files) {
    if (-not (Test-Path -LiteralPath $File.Source -PathType Leaf)) { throw "Release file is missing: $($File.Source)" }
    $Destination = Join-Path $Stage $File.Destination
    New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $File.Source -Destination $Destination -Force
}

$Manifest = [ordered]@{
    schema = 1
    product = "ZCodeStatusLight"
    version = $Version
    platform = "windows-x64"
    generatedAtUtc = [DateTime]::UtcNow.ToString("o")
}
$Manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Stage "release-manifest.json") -Encoding utf8

$HashFiles = Get-ChildItem -LiteralPath $Stage -File -Recurse | Sort-Object FullName
$Hashes = foreach ($File in $HashFiles) {
    $Relative = $File.FullName.Substring($Stage.Length + 1).Replace("\", "/")
    "{0}  {1}" -f (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $Relative
}
$Hashes | Set-Content -LiteralPath (Join-Path $Stage "SHA256SUMS.txt") -Encoding ascii

Get-ChildItem -LiteralPath $Stage | Compress-Archive -DestinationPath $ZipPath -CompressionLevel Optimal -Force
$ZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$ZipHash  $([System.IO.Path]::GetFileName($ZipPath))" | Set-Content -LiteralPath "$ZipPath.sha256" -Encoding ascii

Write-Host "Created Release ZIP: $ZipPath"
Write-Host "SHA-256: $ZipHash"
