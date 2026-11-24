[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionPath,
    [string]$Scene,
    [switch]$Detail,
    # Wait up to this many seconds (max 110) for this run's AE report to complete before reading.
    [ValidateRange(0, 110)][int]$WaitSeconds = 0
)

# Read-only projection. Finish remains the authority for saved-only completion.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
try {
    $path = [IO.Path]::GetFullPath($SessionPath)
    if ($WaitSeconds -gt 0) {
        # Polls the report locally so a caller needs no separate sleep command.
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        $waitReport = Join-Path (Split-Path $path -Parent) 'ae.report.json'
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $waitReport -PathType Leaf) {
                try { if ((Get-Content -Raw -LiteralPath $waitReport -Encoding UTF8 | ConvertFrom-Json).complete -eq $true) { break } } catch {}
            }
            Start-Sleep -Seconds 3
        }
    }
    $session = Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json
    if (-not $session.run_id -or -not $session.scenes) { throw 'Invalid session: missing run_id or scenes.' }
    $reportPath = Join-Path (Split-Path $path -Parent) 'ae.report.json'
    $report = $null
    $reportState = 'missing'
    $readError = $null
    if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
        try {
            $report = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8 | ConvertFrom-Json
            if ($report.run_id -cne $session.run_id) { throw 'AE report belongs to another run.' }
            $reportState = 'ready'
        } catch {
            $report = $null
            $reportState = 'unreadable_or_mismatched'
            $readError = $_.Exception.Message
        }
    }
    $entries = @($session.scenes | Where-Object { -not $Scene -or $_.scene -ceq $Scene })
    if (-not $entries.Count) { throw "Scene not in this session: $Scene" }
    $scenes = @($entries | ForEach-Object {
        $entry = $_
        $matches = @($report.results | Where-Object { $_.scene -ceq $entry.scene })
        $result = if ($matches.Count -eq 1) { $matches[0] } else { $null }
        $application = $result.application
        $camera = if ($application.camera) { $application.camera } else { $entry.camera_decision }
        if ($camera -and -not $Detail) {
            $camera = [ordered]@{
                ok = $camera.ok
                mode = $camera.mode
                status = $camera.status
                reason = $camera.reason
                error = $camera.error
                warnings = @($camera.warnings)
                total_frames = $camera.total_frames
                used_rgb_copy = $camera.used_rgb_copy
                keys = @($camera.keys | Where-Object { $null -ne $_ } | Select-Object frame, label, slow)
            }
        }
        $fx = $application.characterFX
        if ($fx -and -not $Detail) {
            $fx = [ordered]@{
                error = $fx.error
                warnings = @($fx.warnings)
                tracks = @($fx.tracks | ForEach-Object {
                    [ordered]@{
                        caption = $_.caption
                        status = $_.status
                        reason = $_.reason
                        characters = @($_.characters | Select-Object character, status, reason, fx_only)
                    }
                })
            }
        }
        [ordered]@{
            scene = $entry.scene
            state = $entry.state
            folder = $entry.folder
            inspection_manifest = $entry.inspection_manifest
            template = $entry.template
            output_aep_name = $entry.output_aep_name
            output_ardj_name = $entry.output_ardj_name
            error = $entry.error
            failure = $entry.failure
            result_count = $matches.Count
            ae_ok = $result.ok
            ae_error = $result.error
            application_error = $application.error
            save_check = $result.save_check
            mapped = @($application.applied)
            excluded = @($application.skipped)
            duration_frames = $application.durationSync.frames
            cell_order = @($application.cellLayerOrderTopToBottom)
            camera = $camera
            character_fx = $fx
            warnings = @($entry.warnings)
            application_warnings = @($application.reviewWarnings)
            layout_warnings = @($application.layout.warnings)
            layout_skipped = @($application.layout.skipped)
            timing = $entry.timing
            originals_unchanged = $entry.originals_unchanged
            camera_evidence_unchanged = $entry.camera_evidence_unchanged
        }
    })
    [ordered]@{
        read_ok = ($reportState -ne 'unreadable_or_mismatched')
        session = $path
        run_id = $session.run_id
        state = $session.state
        completion_policy = $session.completion_policy
        elapsed_seconds = $session.elapsed_seconds
        template_unchanged = $session.template_unchanged
        report_path = $reportPath
        report_state = $reportState
        read_error = $readError
        report_error = $report.error
        report_complete = ($reportState -eq 'ready' -and $report.complete -is [bool] -and $report.complete)
        finish_recorded = [bool]$session.finished
        finish_ok = $session.ok
        scenes = $scenes
    } | ConvertTo-Json -Depth 40 -Compress
    if ($readError) { exit 2 }
} catch {
    [ordered]@{read_ok = $false; error = $_.Exception.Message} | ConvertTo-Json
    exit 2
}
