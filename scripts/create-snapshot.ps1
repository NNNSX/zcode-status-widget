[CmdletBinding()]
param(
    [string]$SnapshotRoot,
    [string]$ReleaseRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
if (-not $SnapshotRoot) { $SnapshotRoot = Join-Path $ProjectRoot "snapshots" }
if (-not $ReleaseRoot) { $ReleaseRoot = Join-Path $ProjectRoot "release" }
$VersionSource = Get-Content -LiteralPath (Join-Path $ProjectRoot "version.py") -Raw -Encoding utf8
if ($VersionSource -notmatch 'VERSION\s*=\s*["'']([^"'']+)["'']') { throw "Could not read project version." }
$Version = $matches[1]
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$SnapshotPath = Join-Path ([System.IO.Path]::GetFullPath($SnapshotRoot)) $Timestamp
$SourceStage = Join-Path ([System.IO.Path]::GetTempPath()) ("zcode-status-snapshot-" + [guid]::NewGuid().ToString("N"))
$SourceZipName = "ZCodeStatusLight-v$Version-source.zip"
$ReleaseZipName = "ZCodeStatusLight-v$Version-windows-x64.zip"
$ReleaseZip = Join-Path ([System.IO.Path]::GetFullPath($ReleaseRoot)) $ReleaseZipName
$ReleaseHash = "$ReleaseZip.sha256"

$SourceFiles = @(
    ".gitignore",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "THIRD_PARTY_NOTICES.md",
    "requirements-build.txt",
    "version.py",
    "widget.py",
    "hook_handler.py",
    "build_exe.bat",
    "install.ps1",
    "uninstall.ps1",
    "test_handler.py",
    "test_tooltip.py",
    "test_opacity_regression.py",
    "test_session_display.py",
    "test_stability.py",
    "test_release_scripts.ps1",
    "test_release_package.ps1",
    "docs\zcode-hooks.example.json",
    "scripts\build-release.ps1",
    "scripts\package-release.ps1",
    "scripts\create-snapshot.ps1"
)

if (Test-Path -LiteralPath $SnapshotPath) { throw "Snapshot directory already exists: $SnapshotPath" }
if (-not (Test-Path -LiteralPath $ReleaseZip -PathType Leaf)) { throw "Release ZIP is missing: $ReleaseZip" }
if (-not (Test-Path -LiteralPath $ReleaseHash -PathType Leaf)) { throw "Release ZIP checksum is missing: $ReleaseHash" }

New-Item -ItemType Directory -Path $SnapshotPath -Force | Out-Null
New-Item -ItemType Directory -Path $SourceStage -Force | Out-Null
try {
    foreach ($relative in $SourceFiles) {
        $source = Join-Path $ProjectRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Snapshot source is missing: $relative" }
        $destination = Join-Path $SourceStage $relative
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $SourceZip = Join-Path $SnapshotPath $SourceZipName
    Get-ChildItem -LiteralPath $SourceStage | Compress-Archive -DestinationPath $SourceZip -CompressionLevel Optimal -Force
    Copy-Item -LiteralPath $ReleaseZip -Destination (Join-Path $SnapshotPath $ReleaseZipName) -Force
    Copy-Item -LiteralPath $ReleaseHash -Destination (Join-Path $SnapshotPath "$ReleaseZipName.sha256") -Force

    $SnapshotNote = @"
# Release Snapshot

- Version: $Version
- Created: $([DateTime]::UtcNow.ToString("o"))
- Source archive: $SourceZipName
- Release archive: $ReleaseZipName

This snapshot is a private rollback point. It intentionally excludes desktop screenshots, ZCode configuration, hook logs, registry exports, build intermediates, and private historical snapshots.
"@
    Set-Content -LiteralPath (Join-Path $SnapshotPath "SNAPSHOT.md") -Value $SnapshotNote -Encoding utf8

    $HashLines = Get-ChildItem -LiteralPath $SnapshotPath -File | Where-Object { $_.Name -ne "SHA256SUMS.txt" } | Sort-Object Name | ForEach-Object {
        "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    }
    $HashLines | Set-Content -LiteralPath (Join-Path $SnapshotPath "SHA256SUMS.txt") -Encoding ascii
    Write-Host "Created snapshot: $SnapshotPath"
}
finally {
    Remove-Item -LiteralPath $SourceStage -Recurse -Force -ErrorAction SilentlyContinue
}
