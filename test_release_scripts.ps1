[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseRoot
)

$ErrorActionPreference = "Stop"
$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$InstallScript = Join-Path $ReleaseRoot "install.ps1"
$UninstallScript = Join-Path $ReleaseRoot "uninstall.ps1"
if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) { throw "Release installer is missing: $InstallScript" }
if (-not (Test-Path -LiteralPath $UninstallScript -PathType Leaf)) { throw "Release uninstaller is missing: $UninstallScript" }

function Invoke-ReleaseScript([string]$ScriptPath, [string[]]$Arguments, [switch]$ExpectFailure) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        if ($exitCode -eq 0) { throw "Expected failure but script succeeded: $ScriptPath" }
        return
    }
    if ($exitCode -ne 0) { throw "Script failed ($exitCode): $ScriptPath" }
}

function Read-Json([string]$Path) {
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
}

function Get-RuleToken($Rule) {
    $hooks = @($Rule.hooks)
    if ($hooks.Count -ne 1) { return "" }
    $args = @($hooks[0].args)
    if ($args.Count -lt 2) { return "" }
    return [string]$args[1]
}

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zcode-status-release-test-" + [guid]::NewGuid().ToString("N"))
$InstallRoot = Join-Path $TempRoot "installed"
$ConfigPath = Join-Path $TempRoot "config.json"
$FailureConfigPath = Join-Path $TempRoot "failure-config.json"
$BadReleaseRoot = Join-Path $TempRoot "bad-release"
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

$thirdPartyRule = [ordered]@{
    matcher = "ThirdPartyTool"
    hooks = @([ordered]@{
        type = "process"
        command = "C:\\third-party\\python.exe"
        args = @("C:\\third-party\\handler.py", "custom-event")
        timeoutMs = 1234
    })
}
$fixture = [ordered]@{
    mcp = [ordered]@{ thirdParty = [ordered]@{ enabled = $true } }
    hooks = [ordered]@{
        enabled = $true
        events = [ordered]@{
            UserPromptSubmit = @($thirdPartyRule)
            CustomEvent = @($thirdPartyRule)
        }
    }
}
$fixtureJson = $fixture | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($ConfigPath, $fixtureJson, (New-Object System.Text.UTF8Encoding($false)))

try {
    Invoke-ReleaseScript $InstallScript @("-InstallRoot", $InstallRoot, "-ConfigPath", $ConfigPath, "-NoLaunch")
    $installed = Read-Json $ConfigPath
    Assert ([bool]$installed.mcp.thirdParty.enabled) "Installer changed third-party MCP data."
    Assert (@($installed.hooks.events.CustomEvent).Count -eq 1) "Installer changed an unrelated hook event."
    Assert ((Get-RuleToken @($installed.hooks.events.UserPromptSubmit)[0]) -eq "custom-event") "Installer replaced the existing third-party rule."

    $managed = @{
        UserPromptSubmit = "user_prompt_submit"
        PermissionRequest = "permission_request"
        PostToolUse = "todo_update"
        PostToolUseFailure = "tool_failure"
        Stop = "stop"
    }
    foreach ($event in $managed.Keys) {
        $matches = @($installed.hooks.events.$event | Where-Object { (Get-RuleToken $_) -eq $managed[$event] })
        Assert ($matches.Count -eq 1) "Installer did not add exactly one managed rule for $event."
    }

    Invoke-ReleaseScript $InstallScript @("-InstallRoot", $InstallRoot, "-ConfigPath", $ConfigPath, "-NoLaunch")
    $reinstalled = Read-Json $ConfigPath
    foreach ($event in $managed.Keys) {
        $matches = @($reinstalled.hooks.events.$event | Where-Object { (Get-RuleToken $_) -eq $managed[$event] })
        Assert ($matches.Count -eq 1) "Repeat install duplicated the managed rule for $event."
    }

    Invoke-ReleaseScript $UninstallScript @("-InstallRoot", $InstallRoot, "-ConfigPath", $ConfigPath)
    $uninstalled = Read-Json $ConfigPath
    Assert ([bool]$uninstalled.mcp.thirdParty.enabled) "Uninstaller changed third-party MCP data."
    Assert (@($uninstalled.hooks.events.CustomEvent).Count -eq 1) "Uninstaller changed an unrelated hook event."
    Assert ((Get-RuleToken @($uninstalled.hooks.events.UserPromptSubmit)[0]) -eq "custom-event") "Uninstaller removed the third-party rule."
    foreach ($event in $managed.Keys) {
        $rules = @($uninstalled.hooks.events.$event)
        $matches = @($rules | Where-Object { (Get-RuleToken $_) -eq $managed[$event] })
        Assert ($matches.Count -eq 0) "Uninstaller left a managed rule for $event."
    }
    Invoke-ReleaseScript $UninstallScript @("-InstallRoot", $InstallRoot, "-ConfigPath", $ConfigPath)

    [System.IO.File]::WriteAllText($FailureConfigPath, $fixtureJson, (New-Object System.Text.UTF8Encoding($false)))
    $beforeFailure = [System.IO.File]::ReadAllBytes($FailureConfigPath)
    Copy-Item -LiteralPath $ReleaseRoot -Destination $BadReleaseRoot -Recurse -Force
    Add-Content -LiteralPath (Join-Path $BadReleaseRoot "hook_handler.py") -Value "# modified after release hash" -Encoding utf8
    Invoke-ReleaseScript (Join-Path $BadReleaseRoot "install.ps1") @("-InstallRoot", (Join-Path $TempRoot "bad-installed"), "-ConfigPath", $FailureConfigPath, "-NoLaunch") -ExpectFailure
    $afterFailure = [System.IO.File]::ReadAllBytes($FailureConfigPath)
    Assert (($beforeFailure.Length -eq $afterFailure.Length) -and ([Convert]::ToBase64String($beforeFailure) -eq [Convert]::ToBase64String($afterFailure))) "Checksum failure modified the config file."

    Write-Host "RELEASE INSTALL/UNINSTALL TESTS PASSED"
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
