[CmdletBinding()]
param(
    [string]$PythonPath,
    [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot ".."))
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot "dist" }

function Test-PythonMinimumVersion([string]$Command, [int]$MinimumMinor) {
    try {
        $output = (& $Command --version 2>&1 | Select-Object -First 1).ToString()
        if ($output -notmatch 'Python\s+(\d+)\.(\d+)') { return $false }
        return ([int]$matches[1] -gt 3 -or ([int]$matches[1] -eq 3 -and [int]$matches[2] -ge $MinimumMinor))
    }
    catch { return $false }
}

function Resolve-Python([string]$Requested) {
    if ($Requested) {
        if (-not (Test-Path -LiteralPath $Requested -PathType Leaf)) {
            throw "The requested Python executable was not found: $Requested"
        }
        if (-not (Test-PythonMinimumVersion $Requested 9)) { throw "Building requires Python 3.9 or newer." }
        return @($Requested)
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $paths = & py -0p 2>$null | ForEach-Object {
            if ($_ -match '([A-Za-z]:\\.*python\.exe)\s*$') { $matches[1] }
        }
        foreach ($path in $paths) {
            if (Test-PythonMinimumVersion $path 9) { return @($path) }
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python -and (Test-PythonMinimumVersion $python.Source 9)) { return @($python.Source) }
    throw "Python 3.9 or newer is required. Pass -PythonPath to select an interpreter."
}

if ($env:OS -ne "Windows_NT") { throw "This build script only supports Windows." }
$Python = Resolve-Python $PythonPath
$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
$BuildRoot = Join-Path $ProjectRoot "build"

Push-Location $ProjectRoot
try {
    & $Python -m pip install --disable-pip-version-check -r requirements-build.txt
    if ($LASTEXITCODE -ne 0) { throw "Build dependency installation failed." }

    & $Python -m PyInstaller --onefile --noconsole --name ZCodeStatusLight --clean --noconfirm `
        --distpath $OutputRoot --workpath $BuildRoot --specpath $BuildRoot widget.py
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller build failed." }

    $Version = (Get-Content -LiteralPath "version.py" -Raw -Encoding utf8 | Select-String -Pattern 'VERSION\s*=\s*["'']([^"'']+)["'']' -AllMatches).Matches[0].Groups[1].Value
    Write-Host "Built ZCodeStatusLight v${Version}: $(Join-Path $OutputRoot 'ZCodeStatusLight.exe')"
}
finally {
    Pop-Location
}
