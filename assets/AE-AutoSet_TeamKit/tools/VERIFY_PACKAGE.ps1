$ErrorActionPreference = 'Stop'
$kitRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$required = @(
    '.ae-autoset.example.json',
    'tools\bin\AE_TimesheetSession.exe',
    'tools\RUN_SESSION.cmd',
    'tools\session\AE_TimesheetSession.jsx',
    'tools\session\AE_BatchSceneCore.jsxinc',
    'tools\session\AE_VerifySupport.jsxinc',
    'tools\session\AE_SavedVerifier.jsxinc',
    'tools\session\AE_RemapExceedCore.jsxinc',
    'tools\session\AE_LayoutImport.jsxinc',
    'tools\session\AE_CellCanvas.jsxinc',
    'tools\session\AE_CameraLayout.jsxinc',
    'tools\session\json2.jsxinc',
    'templates\am_timesheet_v1.json',
    'schemas\review.schema.json',
    'schemas\camera.plan.schema.json',
    'schemas\project-profile.schema.json',
    'docs\CAMERA_LAYOUT_KO.md',
    'SHA256SUMS.txt'
)
$failed = $false

Write-Host "Package root: $kitRoot"
foreach ($relative in $required) {
    $path = Join-Path $kitRoot $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-Host "[OK] $relative"
    } else {
        Write-Host "[MISSING] $relative" -ForegroundColor Red
        $failed = $true
    }
}

$manifest = Join-Path $kitRoot 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $manifest -PathType Leaf) {
    foreach ($line in Get-Content -LiteralPath $manifest -Encoding UTF8) {
        if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') { continue }
        $expected = $Matches[1].ToUpperInvariant()
        $relative = $Matches[2].Replace('/', [IO.Path]::DirectorySeparatorChar)
        $path = Join-Path $kitRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host "[HASH MISSING] $relative" -ForegroundColor Red
            $failed = $true
            continue
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -eq $expected) {
            Write-Host "[HASH OK] $relative"
        } else {
            Write-Host "[HASH FAIL] $relative" -ForegroundColor Red
            $failed = $true
        }
    }
}

$adobeRoot = Join-Path $env:ProgramFiles 'Adobe'
$afterFx = Get-ChildItem -LiteralPath $adobeRoot -Filter 'AfterFX.exe' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object FullName -Like '*Adobe After Effects 2025*' |
    Select-Object -First 1
if ($afterFx) {
    Write-Host "[OK] After Effects: $($afterFx.FullName)"
} else {
    Write-Host '[WARNING] Adobe After Effects 2025 was not found in the default location.' -ForegroundColor Yellow
}

if ($failed) {
    Write-Host 'Package verification failed.' -ForegroundColor Red
    exit 2
}
Write-Host 'Package verification succeeded.' -ForegroundColor Green
