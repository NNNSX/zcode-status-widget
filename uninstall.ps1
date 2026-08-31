[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "ZCodeStatusLight"),
    [string]$ConfigPath,
    [switch]$PurgeUserData,
    [switch]$RestoreEnabledState
)

$ErrorActionPreference = "Stop"
$ManagedSpecs = @(
    [pscustomobject]@{ Event = "UserPromptSubmit"; Token = "user_prompt_submit"; Matcher = $null },
    [pscustomobject]@{ Event = "PermissionRequest"; Token = "permission_request"; Matcher = $null },
    [pscustomobject]@{ Event = "PostToolUse"; Token = "todo_update"; Matcher = "TodoWrite" },
    [pscustomobject]@{ Event = "PostToolUseFailure"; Token = "tool_failure"; Matcher = $null },
    [pscustomobject]@{ Event = "Stop"; Token = "stop"; Matcher = $null }
)

function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-Value($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
    else { $property.Value = $Value }
}

function Remove-Value($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $Object.PSObject.Properties.Remove($Name) }
}

function Normalize-PathValue([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    try { return [System.IO.Path]::GetFullPath($PathValue.Trim('"')).TrimEnd([char]92, [char]47).ToLowerInvariant() }
    catch { return $PathValue.Trim('"').TrimEnd([char]92, [char]47).ToLowerInvariant() }
}

function Test-ManagedRule($Rule, $Spec, [string]$HandlerPath) {
    if ($null -eq $Rule) { return $false }
    $matcher = Get-Value $Rule "matcher"
    if ($null -eq $Spec.Matcher) {
        if (-not [string]::IsNullOrEmpty([string]$matcher)) { return $false }
    }
    elseif ([string]$matcher -ne [string]$Spec.Matcher) { return $false }

    $hooks = @(Get-Value $Rule "hooks")
    if ($hooks.Count -ne 1) { return $false }
    $hook = $hooks[0]
    if ([string](Get-Value $hook "type") -ne "process") { return $false }
    if ([string](Get-Value $hook "timeoutMs") -ne "5000") { return $false }
    $args = @(Get-Value $hook "args")
    if ($args.Count -ne 4) { return $false }
    return ((Normalize-PathValue ([string]$args[0])) -eq (Normalize-PathValue $HandlerPath) -and
            [string]$args[1] -eq [string]$Spec.Token -and
            [string]$args[2] -eq '${CLAUDE_SESSION_ID}' -and
            [string]$args[3] -eq '${ZCODE_PROJECT_DIR}')
}

function Write-JsonAtomically($Object, [string]$Path) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path $Path -Leaf), [guid]::NewGuid().ToString("N"))
    $replaceBackup = "$temporary.previous"
    $json = $Object | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    try { [System.IO.File]::Replace($temporary, $Path, $replaceBackup, $true) }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-RawConfig([byte[]]$Bytes, [string]$Path) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".{0}.{1}.restore" -f (Split-Path $Path -Leaf), [guid]::NewGuid().ToString("N"))
    $replaceBackup = "$temporary.previous"
    [System.IO.File]::WriteAllBytes($temporary, $Bytes)
    try { [System.IO.File]::Replace($temporary, $Path, $replaceBackup, $true) }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $replaceBackup) { Remove-Item -LiteralPath $replaceBackup -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-InstalledProcesses([string]$ExePath) {
    $target = Normalize-PathValue $ExePath
    $processes = @(Get-Process -Name "ZCodeStatusLight" -ErrorAction SilentlyContinue | Where-Object {
        try { (Normalize-PathValue $_.Path) -eq $target } catch { $false }
    })
    foreach ($process in $processes) { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
    if ($processes.Count -gt 0) { Wait-Process -Id $processes.Id -Timeout 5 -ErrorAction SilentlyContinue }
}

if ($env:OS -ne "Windows_NT") { throw "This uninstaller only supports Windows." }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or later is required." }
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    Write-Host "ZCodeStatusLight is already removed: $InstallRoot"
    exit 0
}
$StatePath = Join-Path $InstallRoot "install-state.json"
if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    throw "Install state is missing. Refusing to guess which ZCode hooks to remove."
}
$State = Get-Content -LiteralPath $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
if (-not $ConfigPath) { $ConfigPath = [string](Get-Value $State "configPath") }
if (-not $ConfigPath) { throw "Config path is missing from install state. Pass -ConfigPath explicitly." }
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "ZCode config was not found: $ConfigPath" }
$HandlerPath = [string](Get-Value $State "handlerPath")
if ((Normalize-PathValue $HandlerPath) -ne (Normalize-PathValue (Join-Path $InstallRoot "hook_handler.py"))) {
    throw "Install state handler path does not match the selected install root."
}

$ConfigBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
try { $Config = [System.Text.Encoding]::UTF8.GetString($ConfigBytes) | ConvertFrom-Json -ErrorAction Stop }
catch { throw "ZCode config is not valid JSON: $ConfigPath" }
$hooks = Get-Value $Config "hooks"
if ($null -ne $hooks) {
    $events = Get-Value $hooks "events"
    if ($null -ne $events) {
        foreach ($spec in $ManagedSpecs) {
            $rules = @(Get-Value $events $spec.Event)
            if ($rules.Count -eq 0) { continue }
            $remaining = @($rules | Where-Object { -not (Test-ManagedRule $_ $spec $HandlerPath) })
            $createdEvents = @((Get-Value $State "createdEvents"))
            if ($remaining.Count -eq 0 -and $createdEvents -contains $spec.Event) {
                Remove-Value $events $spec.Event
            }
            else {
                Set-Value $events $spec.Event $remaining
            }
        }
    }

    if ($RestoreEnabledState -and [bool](Get-Value $State "enabledWasFalse")) {
        $hasAnyRules = $false
        $remainingEvents = Get-Value $hooks "events"
        if ($null -ne $remainingEvents) {
            foreach ($property in $remainingEvents.PSObject.Properties) {
                if (@($property.Value).Count -gt 0) { $hasAnyRules = $true; break }
            }
        }
        if (-not $hasAnyRules) { Set-Value $hooks "enabled" $false }
    }

    $eventsAfter = Get-Value $hooks "events"
    $hasEventProperties = $null -ne $eventsAfter -and $eventsAfter.PSObject.Properties.Count -gt 0
    $onlyInstallerStructure = [bool](Get-Value $State "createdHooks") -and -not $hasEventProperties
    if ($onlyInstallerStructure) { Remove-Value $Config "hooks" }
}

$backupDir = Join-Path (Split-Path -Parent $ConfigPath) ".zcode-status-light-backups"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
$configBackup = Join-Path $backupDir ("config-before-uninstall-{0}.json" -f $timestamp)
[System.IO.File]::WriteAllBytes($configBackup, $ConfigBytes)
$written = $false
try {
    Write-JsonAtomically $Config $ConfigPath
    $written = $true
    $roundTrip = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    foreach ($spec in $ManagedSpecs) {
        $roundHooks = Get-Value $roundTrip "hooks"
        $roundEvents = Get-Value $roundHooks "events"
        $rules = @(Get-Value $roundEvents $spec.Event)
        if (@($rules | Where-Object { Test-ManagedRule $_ $spec $HandlerPath }).Count -ne 0) {
            throw "Post-write hook verification failed for $($spec.Event)."
        }
    }
}
catch {
    if ($written) {
        try { Restore-RawConfig $ConfigBytes $ConfigPath } catch { Write-Warning "Could not restore the previous ZCode config automatically." }
    }
    throw
}

Stop-InstalledProcesses (Join-Path $InstallRoot "ZCodeStatusLight.exe")
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
try {
    $runValue = (Get-ItemProperty -Path $runKey -Name "ZCodeStatusLight" -ErrorAction Stop).ZCodeStatusLight
    if ((Normalize-PathValue ([string]$runValue)) -eq (Normalize-PathValue (Join-Path $InstallRoot "ZCodeStatusLight.exe"))) {
        Remove-ItemProperty -Path $runKey -Name "ZCodeStatusLight" -ErrorAction Stop
    }
}
catch [System.Management.Automation.ItemNotFoundException] {
}
catch {
    Write-Warning "Could not inspect or remove the matching autostart value: $($_.Exception.Message)"
}

if ($PurgeUserData) {
    $configBackupDir = Join-Path (Split-Path -Parent $ConfigPath) ".zcode-status-light-backups"
    Remove-Item -LiteralPath $configBackupDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "HKCU:\Software\ZCodeStatusLight" -Recurse -Force -ErrorAction SilentlyContinue
    $localAppData = $env:LOCALAPPDATA
    if (-not $localAppData) { $localAppData = $HOME }
    $logDir = Join-Path $localAppData "zcode-status"
    Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $InstallRoot -Recurse -Force
Write-Host "Uninstalled ZCodeStatusLight. A ZCode config backup was saved to $configBackup. Interface preferences and diagnostic logs were preserved unless -PurgeUserData was used."
