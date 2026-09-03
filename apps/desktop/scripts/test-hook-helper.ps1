$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$appsRoot = Split-Path -Parent $projectRoot
$helperSource = Join-Path $appsRoot "hook-helper\ZCodeStatusHook.cs"
$testSource = Join-Path $appsRoot "hook-helper\ZCodeStatusHook.Tests.cs"
$csharpCompiler = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$temporaryRoot = Join-Path $env:TEMP "zcode-status-hook-tests-$PID"
$output = Join-Path $temporaryRoot "ZCodeStatusHook.Tests.exe"

if (-not (Test-Path -LiteralPath $helperSource -PathType Leaf)) {
  throw "Native Hook Helper source is missing: $helperSource"
}
if (-not (Test-Path -LiteralPath $testSource -PathType Leaf)) {
  throw "Native Hook Helper test source is missing: $testSource"
}
if (-not (Test-Path -LiteralPath $csharpCompiler -PathType Leaf)) {
  throw "Windows .NET Framework C# compiler is missing: $csharpCompiler"
}

New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
try {
  & $csharpCompiler /nologo /target:exe /main:HookInputTests "/out:$output" /reference:System.Web.dll $helperSource $testSource
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Native Hook Helper test build failed with exit code $LASTEXITCODE."
  }
  & $output
  if ($LASTEXITCODE -ne 0) {
    throw "Native Hook Helper tests failed with exit code $LASTEXITCODE."
  }
} finally {
  Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
