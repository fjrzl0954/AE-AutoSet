[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Validate', 'Version', 'Profile', 'Begin', 'Prepare', 'Launch', 'Finish')]
    [string]$Action,
    [string]$TargetPath,
    [string]$SessionPath,
    [string]$AfterFX,
    [string]$Only,
    [switch]$Overwrite,
    [switch]$RetryDispatch,
    # Send the run to the After Effects that is already open (former behaviour).
    # By default a separate AE opens only for this run and closes itself; the worker's AE is untouched.
    [switch]$ReuseAE,
    # Prepare again only the scenes whose preparation failed (before AE starts).
    [switch]$RetryFailed,
    # Keep _timesheet_auto, _sessions and summaries after Finish (normally removed for saved scenes).
    [switch]$KeepWorkFiles
)

$ErrorActionPreference = 'Stop'
# Result notes follow the AE AutoSet window's language (set by the window, else its saved setting).
if (-not $env:AE_AUTOSET_LANG) {
    try {
        $savedLanguage = [string](Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'AE-AutoSet\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json).language
        if ($savedLanguage -in @('ko', 'ja', 'en', 'zh')) { $env:AE_AUTOSET_LANG = $savedLanguage }
    } catch {}
}
$skillRoot =[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtime = [IO.Path]::GetFullPath((Join-Path $skillRoot 'assets\AE-AutoSet_TeamKit'))
$runner = Join-Path $runtime 'tools\RUN_SESSION.cmd'
$runtimeAliases = @($runtime)
$skillEntry = Get-Item -LiteralPath $skillRoot -Force
if ($skillEntry.LinkType -and $skillEntry.Target) {
    $linkedRoot = [string]@($skillEntry.Target)[0]
    if (-not [IO.Path]::IsPathRooted($linkedRoot)) {
        $linkedRoot = Join-Path (Split-Path $skillRoot -Parent) $linkedRoot
    }
    $runtimeAliases += [IO.Path]::GetFullPath((Join-Path $linkedRoot 'assets\AE-AutoSet_TeamKit'))
}

if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "AE AutoSet runtime is incomplete: $runner"
}
if ($Action -eq 'Validate') {
    $templates = @(Get-ChildItem -LiteralPath $runtime -File -Filter '*.aep' | Sort-Object Name | ForEach-Object Name)
    $projects = Join-Path $runtime 'projects'
    if (Test-Path -LiteralPath $projects) {
        $templates += @(Get-ChildItem -LiteralPath $projects -Directory | Where-Object { $_.Name -notlike '_*' } |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.aep' } |
            ForEach-Object { 'projects/' + $_.Directory.Name + '/' + $_.Name })
    }
    if (-not $templates.Count) { throw "AE AutoSet has no bundled AEP template: $runtime" }
    $engineVersion = & $runner --version
    if ($LASTEXITCODE -ne 0) { throw 'AE AutoSet engine version check failed.' }
    [pscustomobject]@{
        ok = $true
        runtime = $runtime
        runner = $runner
        templates = $templates
        version = ($engineVersion | Out-String).Trim()
    } | ConvertTo-Json
    exit 0
}

if ($Action -eq 'Version') {
    & $runner --version
    exit $LASTEXITCODE
}

if ($Action -in @('Profile', 'Begin')) {
    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        throw "$Action requires -TargetPath."
    }
    $target = [IO.Path]::GetFullPath($TargetPath)
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Work path does not exist: $target"
    }
    $commandName = if ($Action -eq 'Profile') { 'profile' } else { 'begin' }
    $arguments = @($commandName, '--root', $target)
    if (-not [string]::IsNullOrWhiteSpace($Only)) { $arguments += @('--only', $Only) }
    if ($Action -eq 'Begin' -and $Overwrite) { $arguments += '--overwrite' }
    & $runner @arguments
    exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($SessionPath)) {
    throw "$Action requires -SessionPath."
}
$session = [IO.Path]::GetFullPath($SessionPath)
if (-not (Test-Path -LiteralPath $session -PathType Leaf)) {
    throw "Session file does not exist: $session"
}
$sessionData = Get-Content -Raw -LiteralPath $session -Encoding UTF8 | ConvertFrom-Json
foreach ($scene in @($sessionData.scenes)) {
    $sessionTemplate = [IO.Path]::GetFullPath([string]$(if ($scene.template) { $scene.template } else { $sessionData.template }))
    $templateMatches = $false
    foreach ($candidate in $runtimeAliases) {
        $candidateRoot = [IO.Path]::GetFullPath($candidate).TrimEnd('\') + '\'
        if ($sessionTemplate.StartsWith($candidateRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $templateMatches = $true
            break
        }
    }
    if (-not $templateMatches) { throw "Session template is outside this TeamKit runtime: $sessionTemplate" }
    if (-not (Test-Path -LiteralPath $sessionTemplate -PathType Leaf)) { throw "Session template is missing: $sessionTemplate" }
    $expectedHash = [string]$(if ($scene.template_sha256) { $scene.template_sha256 } else { $sessionData.template_sha256 })
    if ($expectedHash -ne (Get-FileHash -LiteralPath $sessionTemplate -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw "Session template hash differs from the current bundled template: $sessionTemplate"
    }
}
if ([string]$sessionData.completion_policy -ne 'saved_only_v1') {
    throw "Session completion policy is not supported by AE AutoSet: $($sessionData.completion_policy)"
}

$arguments = switch ($Action) {
    'Prepare' { @('prepare', '--session', $session) + $(if ($RetryFailed) { @('--retry-failed') } else { @() }) }
    'Launch'  { @('launch-ae', '--session', $session) }
    'Finish'  { @('finish', '--session', $session) + $(if ($KeepWorkFiles) { @('--keep-work-files') } else { @() }) }
}
if ($Action -eq 'Launch' -and [string]::IsNullOrWhiteSpace($AfterFX)) {
    # The settings window remembers the worker's chosen After Effects.
    $state = Join-Path $env:LOCALAPPDATA 'AE-AutoSet\settings.json'
    if (Test-Path -LiteralPath $state) {
        try { $saved = [string](Get-Content -Raw -LiteralPath $state -Encoding UTF8 | ConvertFrom-Json).afterfx } catch { $saved = '' }
        if ($saved -and (Test-Path -LiteralPath $saved -PathType Leaf)) { $AfterFX = $saved }
    }
}
if ($Action -eq 'Launch' -and -not [string]::IsNullOrWhiteSpace($AfterFX)) {
    $arguments += @('--afterfx', [IO.Path]::GetFullPath($AfterFX))
}
if ($Action -eq 'Launch' -and $RetryDispatch) {
    $arguments += '--retry-dispatch'
}
if ($Action -eq 'Launch' -and $ReuseAE) {
    $arguments += '--reuse-ae'
}

& $runner @arguments
exit $LASTEXITCODE
