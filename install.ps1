[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "ZCodeStatusLight"),
    [string]$ConfigPath = (Join-Path $HOME ".zcode\cli\config.json"),
    [string]$PythonPath,
    [string]$LegacyHandlerPath,
    [switch]$EnableHooks,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $PSCommandPath
$ManagedSpecs = @(
    [pscustomobject]@{ Event = "UserPromptSubmit"; Token = "user_prompt_submit"; Matcher = $null },
    [pscustomobject]@{ Event = "PermissionRequest"; Token = "permission_bash"; Matcher = "^Bash$" },
    [pscustomobject]@{ Event = "PermissionRequest"; Token = "permission_request"; Matcher = "^(?!Bash$).+" },
    [pscustomobject]@{ Event = "PostToolUse"; Token = "todo_update"; Matcher = "TodoWrite" },
    [pscustomobject]@{ Event = "PostToolUseFailure"; Token = "tool_failure"; Matcher = $null },
    [pscustomobject]@{ Event = "Stop"; Token = "stop"; Matcher = $null }
)
$LegacyPermissionSpec = [pscustomobject]@{ Event = "PermissionRequest"; Token = "permission_request"; Matcher = $null }

function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Set-Value($Object, [string]$Name, $Value) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $property.Value = $Value
    }
}

function Remove-Value($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { $property.Value = $null; $Object.PSObject.Properties.Remove($Name) }
}

function Normalize-PathValue([string]$PathValue) {
    if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
    try {
        return [System.IO.Path]::GetFullPath($PathValue.Trim('"')).TrimEnd([char]92, [char]47).ToLowerInvariant()
    }
    catch {
        return $PathValue.Trim('"').TrimEnd([char]92, [char]47).ToLowerInvariant()
    }
}

function Test-ManagedRule($Rule, $Spec, [string]$HandlerPath) {
    if ($null -eq $Rule) { return $false }
    $matcher = Get-Value $Rule "matcher"
    if ($null -eq $Spec.Matcher) {
        if (-not [string]::IsNullOrEmpty([string]$matcher)) { return $false }
    }
    elseif ([string]$matcher -ne [string]$Spec.Matcher) {
        return $false
    }

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

function New-ManagedRule($Spec, [string]$ResolvedPython, [string]$HandlerPath) {
    $hook = [ordered]@{
        type = "process"
        command = $ResolvedPython
        args = @($HandlerPath, $Spec.Token, '${CLAUDE_SESSION_ID}', '${ZCODE_PROJECT_DIR}')
        timeoutMs = 5000
    }
    $rule = [ordered]@{ hooks = @($hook) }
    if ($null -ne $Spec.Matcher) { $rule = [ordered]@{ matcher = $Spec.Matcher; hooks = @($hook) } }
    return [pscustomobject]$rule
}

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
        $candidate = $Requested
    }
    else {
        $candidate = $null
        $py = Get-Command py -ErrorAction SilentlyContinue
        if ($py) {
            $paths = & py -0p 2>$null | ForEach-Object {
                if ($_ -match '([A-Za-z]:\\.*python\.exe)\s*$') { $matches[1] }
            }
            foreach ($path in $paths) {
                if (Test-PythonMinimumVersion $path 8) { $candidate = $path; break }
            }
        }
        if (-not $candidate) {
            $python = Get-Command python -ErrorAction SilentlyContinue
            if ($python) { $candidate = $python.Source }
        }
    }
    if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Python 3.8+ was not found. Pass -PythonPath with a full interpreter path."
    }
    if (-not (Test-PythonMinimumVersion $candidate 8)) { throw "Python 3.8+ is required for hook_handler.py." }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Test-ReleaseIntegrity([string]$Root) {
    $sumPath = Join-Path $Root "SHA256SUMS.txt"
    if (-not (Test-Path -LiteralPath $sumPath -PathType Leaf)) {
        throw "SHA256SUMS.txt is missing from this Release package."
    }
    $entries = Get-Content -LiteralPath $sumPath -Encoding ascii | Where-Object { $_.Trim() }
    if ($entries.Count -eq 0) { throw "SHA256SUMS.txt is empty." }
    foreach ($entry in $entries) {
        if ($entry -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
            throw "Malformed checksum entry: $entry"
        }
        $expected = $matches[1].ToLowerInvariant()
        $relative = $matches[2].Replace('/', '\')
        if ([System.IO.Path]::IsPathRooted($relative) -or $relative.Split([char]92) -contains '..') {
            throw "Unsafe checksum path: $relative"
        }
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Release file is missing: $relative"
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "Checksum mismatch: $relative" }
    }
}

function Write-JsonAtomically($Object, [string]$Path) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path $Path -Leaf), [guid]::NewGuid().ToString("N"))
    $replaceBackup = "$temporary.previous"
    $json = $Object | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    try {
        [System.IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
    }
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
    try {
        [System.IO.File]::Replace($temporary, $Path, $replaceBackup, $true)
    }
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

if ($env:OS -ne "Windows_NT") { throw "This installer only supports Windows." }
if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or later is required." }

$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "ZCode config was not found: $ConfigPath" }
Test-ReleaseIntegrity $ScriptRoot
$RequiredFiles = @("ZCodeStatusLight.exe", "hook_handler.py", "install.ps1", "uninstall.ps1", "README.md", "LICENSE", "CHANGELOG.md", "THIRD_PARTY_NOTICES.md", "version.py", "SHA256SUMS.txt", "release-manifest.json", "docs\zcode-hooks.example.json")
foreach ($file in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot $file) -PathType Leaf)) { throw "Release file is missing: $file" }
}
$ReleaseManifest = Get-Content -LiteralPath (Join-Path $ScriptRoot "release-manifest.json") -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
$ReleaseVersion = [string](Get-Value $ReleaseManifest "version")
if (-not $ReleaseVersion) { throw "Release manifest does not declare a version." }
$ResolvedPython = Resolve-Python $PythonPath
$SourceHandler = Join-Path $ScriptRoot "hook_handler.py"
$ConfigBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
try {
    $Config = [System.Text.Encoding]::UTF8.GetString($ConfigBytes) | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "ZCode config is not valid JSON: $ConfigPath"
}

$hooks = Get-Value $Config "hooks"
$createdHooks = $false
$createdEnabled = $false
$enabledWasFalse = $false
if ($null -eq $hooks) {
    $hooks = [pscustomobject]@{}
    Set-Value $Config "hooks" $hooks
    $createdHooks = $true
}
elseif ($hooks -is [string] -or $hooks -is [array]) {
    throw "ZCode config field 'hooks' must be a JSON object."
}
$enabled = Get-Value $hooks "enabled"
if ($null -eq $enabled) {
    Set-Value $hooks "enabled" $true
    $createdEnabled = $true
}
elseif (-not [bool]$enabled) {
    if (-not $EnableHooks) {
        throw "ZCode hooks are explicitly disabled. Re-run with -EnableHooks only if you intend to enable them."
    }
    Set-Value $hooks "enabled" $true
    $enabledWasFalse = $true
}
$events = Get-Value $hooks "events"
if ($null -eq $events) {
    $events = [pscustomobject]@{}
    Set-Value $hooks "events" $events
}
elseif ($events -is [string] -or $events -is [array]) {
    throw "ZCode config field 'hooks.events' must be a JSON object."
}

$parent = Split-Path -Parent $InstallRoot
$leaf = Split-Path -Leaf $InstallRoot
$stage = Join-Path $parent (".{0}.stage.{1}" -f $leaf, [guid]::NewGuid().ToString("N"))
$backupDir = Join-Path $InstallRoot "backups"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$written = $false
try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($file in $RequiredFiles) {
        $source = Join-Path $ScriptRoot $file
        $destination = Join-Path $stage $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
    Test-ReleaseIntegrity $stage

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    $configBackup = Join-Path $backupDir ("config-before-{0}.json" -f $timestamp)
    [System.IO.File]::WriteAllBytes($configBackup, $ConfigBytes)
    foreach ($file in @("ZCodeStatusLight.exe", "hook_handler.py")) {
        $existing = Join-Path $InstallRoot $file
        if (Test-Path -LiteralPath $existing -PathType Leaf) {
            Copy-Item -LiteralPath $existing -Destination (Join-Path $backupDir ("{0}-{1}" -f $timestamp, $file)) -Force
        }
    }

    Stop-InstalledProcesses (Join-Path $InstallRoot "ZCodeStatusLight.exe")
    foreach ($file in $RequiredFiles) {
        $source = Join-Path $stage $file
        $destination = Join-Path $InstallRoot $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }

    $handlerPath = Join-Path $InstallRoot "hook_handler.py"
    $createdEvents = @()
    $legacyPermissionRules = @(Get-Value $events $LegacyPermissionSpec.Event)
    if ($legacyPermissionRules.Count -gt 0) {
        Set-Value $events $LegacyPermissionSpec.Event @($legacyPermissionRules | Where-Object {
            -not (Test-ManagedRule $_ $LegacyPermissionSpec $handlerPath)
        })
    }
    foreach ($spec in $ManagedSpecs) {
        $current = Get-Value $events $spec.Event
        if ($null -eq $current) { $createdEvents += $spec.Event }
        $rules = if ($null -eq $current) { @() } else { @($current) }
        $kept = @($rules | Where-Object { -not (Test-ManagedRule $_ $spec $handlerPath) })
        Set-Value $events $spec.Event (@($kept) + @(New-ManagedRule $spec $ResolvedPython $handlerPath))
    }

    if ($LegacyHandlerPath) {
        $legacy = Normalize-PathValue $LegacyHandlerPath
        foreach ($spec in @($ManagedSpecs) + @($LegacyPermissionSpec)) {
            $rules = @(Get-Value $events $spec.Event)
            $filtered = @($rules | Where-Object {
                $candidate = @(Get-Value $_ "hooks")
                if ($candidate.Count -ne 1) { return $true }
                $args = @(Get-Value $candidate[0] "args")
                -not ((Normalize-PathValue ([string]$args[0])) -eq $legacy -and (Test-ManagedRule $_ $spec $LegacyHandlerPath))
            })
            Set-Value $events $spec.Event $filtered
        }
        foreach ($spec in $ManagedSpecs) {
            $rules = @(Get-Value $events $spec.Event)
            if (-not ($rules | Where-Object { Test-ManagedRule $_ $spec $handlerPath })) {
                Set-Value $events $spec.Event (@($rules) + @(New-ManagedRule $spec $ResolvedPython $handlerPath))
            }
        }
    }

    Write-JsonAtomically $Config $ConfigPath
    $written = $true
    $roundTrip = Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    foreach ($spec in $ManagedSpecs) {
        $rules = @(Get-Value (Get-Value (Get-Value $roundTrip "hooks") "events") $spec.Event)
        if (@($rules | Where-Object { Test-ManagedRule $_ $spec $handlerPath }).Count -ne 1) {
            throw "Post-write hook verification failed for $($spec.Event)."
        }
    }

    $state = [ordered]@{
        version = $ReleaseVersion
        installRoot = $InstallRoot
        configPath = $ConfigPath
        handlerPath = $handlerPath
        configBackup = $configBackup
        configBackupSha256 = (Get-FileHash -LiteralPath $configBackup -Algorithm SHA256).Hash.ToLowerInvariant()
        createdHooks = $createdHooks
        createdEnabled = $createdEnabled
        enabledWasFalse = $enabledWasFalse
        createdEvents = @($createdEvents)
        managedEvents = @($ManagedSpecs | ForEach-Object { $_.Event })
    }
    ($state | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $InstallRoot "install-state.json") -Encoding utf8

    if (-not $NoLaunch) {
        Start-Process -FilePath (Join-Path $InstallRoot "ZCodeStatusLight.exe") | Out-Null
    }
    Write-Host "Installed ZCodeStatusLight to $InstallRoot"
    Write-Host "Restart ZCode or open a new session before expecting hooks to fire."
}
catch {
    if ($written) {
        try { Restore-RawConfig $ConfigBytes $ConfigPath } catch { Write-Warning "Could not restore the previous ZCode config automatically." }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
