[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ZipPath
)

$ErrorActionPreference = "Stop"
$ZipPath = [System.IO.Path]::GetFullPath($ZipPath)
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw "Release ZIP is missing: $ZipPath" }
$SidecarPath = "$ZipPath.sha256"
if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) { throw "Release ZIP checksum file is missing: $SidecarPath" }
$ActualZipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$Sidecar = (Get-Content -LiteralPath $SidecarPath -Raw -Encoding ascii).Trim()
if ($Sidecar -notmatch '^([0-9a-f]{64})  ([^\\/]+\.zip)$') { throw "Release ZIP checksum file is malformed." }
if ($matches[1] -ne $ActualZipHash) { throw "Release ZIP checksum does not match." }

$Bytes = [System.IO.File]::ReadAllBytes($ZipPath)
if ($Bytes.Length -lt 4 -or $Bytes[0] -ne 80 -or $Bytes[1] -ne 75) { throw "Release file is not a ZIP archive." }
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zcode-status-verify-" + [guid]::NewGuid().ToString("N"))
try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $TempRoot -Force
    $ExpectedFiles = @(
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "SHA256SUMS.txt",
        "THIRD_PARTY_NOTICES.md",
        "ZCodeStatusLight.exe",
        "docs/zcode-hooks.example.json",
        "hook_handler.py",
        "install.ps1",
        "release-manifest.json",
        "uninstall.ps1",
        "version.py"
    ) | Sort-Object
    $ActualFiles = Get-ChildItem -LiteralPath $TempRoot -File -Recurse | ForEach-Object {
        $_.FullName.Substring($TempRoot.Length + 1).Replace("\", "/")
    } | Sort-Object
    $Diff = Compare-Object -ReferenceObject $ExpectedFiles -DifferenceObject $ActualFiles
    if ($Diff) { throw ("Release file whitelist mismatch: " + ($Diff | Out-String)) }

    $VersionSource = Get-Content -LiteralPath (Join-Path $TempRoot "version.py") -Raw -Encoding utf8
    if ($VersionSource -notmatch 'VERSION\s*=\s*["'']([^"'']+)["'']') {
        throw "Release version source is malformed."
    }
    $ExpectedVersion = $matches[1]
    $Manifest = Get-Content -LiteralPath (Join-Path $TempRoot "release-manifest.json") -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    if ($Manifest.product -ne "ZCodeStatusLight" -or $Manifest.version -ne $ExpectedVersion -or $Manifest.platform -ne "windows-x64") {
        throw "Release manifest has unexpected metadata."
    }

    $HashFailures = @()
    Get-Content -LiteralPath (Join-Path $TempRoot "SHA256SUMS.txt") -Encoding ascii | ForEach-Object {
        if ($_ -notmatch '^([0-9a-f]{64})  (.+)$') {
            $HashFailures += "Malformed checksum entry: $_"
            return
        }
        $RelativePath = $matches[2].Replace("/", "\")
        if ([System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Split([char]92) -contains "..") {
            $HashFailures += "Unsafe checksum path: $RelativePath"
            return
        }
        $FilePath = Join-Path $TempRoot $RelativePath
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            $HashFailures += "Missing checksum file: $RelativePath"
            return
        }
        $ActualHash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ActualHash -ne $matches[1]) { $HashFailures += "Checksum mismatch: $RelativePath" }
    }
    if ($HashFailures.Count -gt 0) { throw ($HashFailures -join "; ") }
    Write-Host "RELEASE ZIP VERIFIED: $ActualZipHash"
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
