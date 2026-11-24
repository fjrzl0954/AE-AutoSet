# Claude Code PreToolUse hook for runs started by the AE AutoSet window.
# Allows only this skill's two scripts and short waits; anything else falls through to the
# normal permission check, which denies it in dontAsk mode. Never prints anything for a denial.
$ErrorActionPreference = 'Stop'
try {
    $stream = [Console]::OpenStandardInput()
    $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
    $data = $reader.ReadToEnd() | ConvertFrom-Json
} catch { exit 0 }

$tool = [string]$data.tool_name
$command = [string]$data.tool_input.command
$root = $env:AE_AUTOSET_SKILL_ROOT
if (-not $root -or -not $command -or ($tool -ne 'PowerShell' -and $tool -ne 'Bash')) { exit 0 }

$allowedScripts = @('Invoke-AutoSet.ps1', 'Read-AutoSetState.ps1') | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $root ('scripts\' + $_))).ToLowerInvariant()
}

function Test-ScriptCall([string]$Text) {
    # & "<script>" args   |   powershell[.exe] [-NoProfile] [-ExecutionPolicy Bypass] -File "<script>" args
    $pattern = '^\s*(?:&\s*|(?:powershell(?:\.exe)?|pwsh(?:\.exe)?)\s+(?:-(?:NoProfile|NonInteractive|NoLogo|ExecutionPolicy\s+\w+)\s+)*-File\s+)(?:"([^"]+)"|''([^'']+)''|(\S+))(.*)$'
    $match = [regex]::Match($Text, $pattern, 'IgnoreCase')
    if (-not $match.Success) { return $false }
    $path = ($match.Groups[1].Value + $match.Groups[2].Value + $match.Groups[3].Value) -replace '/', '\'
    try { $full = [IO.Path]::GetFullPath($path).ToLowerInvariant() } catch { return $false }
    if ($allowedScripts -notcontains $full) { return $false }
    # Arguments: plain parameters and quoted values only; no subexpressions, redirection or escapes.
    $rest = $match.Groups[4].Value
    if ($rest -match '[`$<>]|\$\(' ) { return $false }
    return $true
}

function Test-Statement([string]$Text) {
    $text = $Text.Trim()
    if (-not $text) { return $true }
    if ($text -match '^(Start-Sleep|sleep)(\s+-(Seconds|s|Milliseconds|m))?\s+\d{1,4}$') { return $true }
    # Reading the state as JSON is fine: <state script call> | ConvertFrom-Json / Select-Object / Out-String
    $parts = $text -split '\|'
    if ($parts.Count -gt 1) {
        foreach ($tail in $parts[1..($parts.Count - 1)]) {
            if ($tail.Trim() -notmatch '^(ConvertFrom-Json|Out-String|Select-Object(\s+[\w\-, *]+)?|Format-List(\s+[\w\-, *]+)?)$') { return $false }
        }
    }
    return (Test-ScriptCall $parts[0])
}

# Statements may be joined by ';', '&&' or new lines; every one must be allowed.
$statements = [regex]::Split($command, ';|&&|\r?\n')
foreach ($statement in $statements) { if (-not (Test-Statement $statement)) { exit 0 } }

$decision = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'allow';
                permissionDecisionReason = 'AE AutoSet skill script' } }
[Console]::Out.Write(($decision | ConvertTo-Json -Compress -Depth 4))
exit 0
