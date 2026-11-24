# AE AutoSet "작업 시작": run Claude Code or Codex headlessly with this skill, stream progress, allow stop.
# Dot-sourced by AE-AutoSet.ps1. The AI follows the same SKILL.md as in a chat; only the window replaces the chat.

if (-not ('AEAutoSet.AiRunner' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace AEAutoSet {
  // Starts a console program without a window, feeds UTF-8 stdin, and queues stdout/stderr lines.
  // PowerShell cannot run script blocks on reader threads, so the window drains the queue on a timer.
  public class AiRunner {
    private Process process;
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private int openReaders;
    private StreamWriter log;
    private readonly object logLock = new object();
    public int ExitCode { get; private set; }
    public string LogPath { get; private set; }

    public bool Finished {
      get { return process != null && process.HasExited && Thread.VolatileRead(ref openReaders) == 0; }
    }

    public void Start(string file, string arguments, string workingDirectory, string stdinText,
                      IDictionary<string, string> environment, string logPath) {
      var info = new ProcessStartInfo(file, arguments);
      info.WorkingDirectory = workingDirectory;
      info.UseShellExecute = false;
      info.CreateNoWindow = true;
      info.RedirectStandardInput = true;
      info.RedirectStandardOutput = true;
      info.RedirectStandardError = true;
      if (environment != null) { foreach (var pair in environment) { info.EnvironmentVariables[pair.Key] = pair.Value; } }
      LogPath = logPath;
      if (!string.IsNullOrEmpty(logPath)) {
        Directory.CreateDirectory(Path.GetDirectoryName(logPath));
        log = new StreamWriter(logPath, false, new UTF8Encoding(false));
        log.AutoFlush = true;
      }
      // Process.StandardInput uses the console input encoding; without this a UTF-8 console adds a BOM.
      try { Console.InputEncoding = new UTF8Encoding(false); } catch (Exception) { }
      process = Process.Start(info);
      openReaders = 2;
      StartReader(process.StandardOutput.BaseStream, "O");
      StartReader(process.StandardError.BaseStream, "E");
      var bytes = new UTF8Encoding(false).GetBytes(stdinText ?? "");
      var input = process.StandardInput.BaseStream;
      input.Write(bytes, 0, bytes.Length);
      input.Flush();
      process.StandardInput.Close();
    }

    private void StartReader(Stream stream, string tag) {
      var thread = new Thread(() => {
        try {
          using (var reader = new StreamReader(stream, new UTF8Encoding(false))) {
            string line;
            while ((line = reader.ReadLine()) != null) {
              lines.Enqueue(tag + line);
              if (log != null) { lock (logLock) { log.WriteLine(tag + " " + line); } }
            }
          }
        } catch (Exception) {
        } finally {
          if (Interlocked.Decrement(ref openReaders) == 0) {
            try { process.WaitForExit(); ExitCode = process.ExitCode; } catch (Exception) { }
            if (log != null) { lock (logLock) { log.Dispose(); log = null; } }
          }
        }
      });
      thread.IsBackground = true;
      thread.Start();
    }

    public string[] Drain() {
      var result = new List<string>();
      string line;
      while (lines.TryDequeue(out line)) { result.Add(line); }
      return result.ToArray();
    }

    // Ends the AI and every program it started (a hard stop of the whole process tree).
    public void Stop() {
      if (process == null || process.HasExited) { return; }
      try {
        var kill = new ProcessStartInfo("taskkill.exe", "/T /F /PID " + process.Id);
        kill.UseShellExecute = false; kill.CreateNoWindow = true;
        using (var killer = Process.Start(kill)) { killer.WaitForExit(10000); }
      } catch (Exception) { try { process.Kill(); } catch (Exception) { } }
    }
  }
}
'@
}

$script:AiLabels = @{ claude = 'Claude Code'; codex = 'Codex' }

# ---------------------------------------------------------------- model choice
# Default: the newest top model with extra-high reasoning (Codex: the first model in its list, now GPT-6.2-Sol),
# because handwritten sheet reading needs the strongest model. Each worker may pick another model or
# reasoning level in the window (saved per PC as <target>_model / <target>_effort; empty = default).
$script:AiEffort = 'xhigh'
$script:CodexFallbackModel = 'gpt-6.2-sol'
# Claude aliases always resolve to the newest model of that family.
$script:ClaudeModels = [ordered]@{ fable = 'Fable'; opus = 'Opus'; sonnet = 'Sonnet' }
$script:ClaudeEfforts = @('low', 'medium', 'high', 'xhigh', 'max')
# Versions the aliases pointed to when this was written. Claude Code reports the exact model when a run
# starts; that is remembered per PC (claude_versions) so labels follow new releases.
$script:ClaudeKnownVersions = @{ fable = 'claude-fable-5-2'; opus = 'claude-opus-5-5'; sonnet = 'claude-sonnet-5-5' }

function ConvertFrom-ClaudeModelId([string]$Id) {
    # claude-fable-5-2 -> @{ family = 'fable'; version = '5.2' }; dated IDs such as claude-x-4-5-20250929 work too.
    $match = [regex]::Match($Id, '^claude-([a-z]+)-(\d{1,2})(?:-(\d{1,2}))?(?:-\d{8})?(?:\[.*\])?$')
    if (-not $match.Success) { return $null }
    $version = $match.Groups[2].Value
    if ($match.Groups[3].Success) { $version += '.' + $match.Groups[3].Value }
    return @{ family = $match.Groups[1].Value; version = $version }
}

function Get-ClaudeVersion([string]$Alias) {
    $id = ''
    if ($script:State -and $script:State['claude_versions'] -and $script:State['claude_versions'].Contains($Alias)) {
        $id = [string]$script:State['claude_versions'][$Alias]
    }
    if (-not $id) { $id = $script:ClaudeKnownVersions[$Alias] }
    $parsed = ConvertFrom-ClaudeModelId $id
    if ($parsed) { return $parsed.version }
    return ''
}

function Get-ClaudeModelName([string]$Alias) {
    $version = Get-ClaudeVersion $Alias
    return ($script:ClaudeModels[$Alias] + $(if ($version) { ' ' + $version } else { '' })).Trim()
}

# Remember which exact model an alias ran as (only when the family matches, so a fallback is not mistaken).
function Save-ClaudeVersion([string]$ModelId) {
    $parsed = ConvertFrom-ClaudeModelId $ModelId
    if (-not $parsed -or -not $script:ClaudeModels.Contains($parsed.family) -or -not $script:State) { return $false }
    if (-not $script:State['claude_versions']) { $script:State['claude_versions'] = [ordered]@{} }
    $clean = $ModelId -replace '\[.*\]$', ''
    if ([string]$script:State['claude_versions'][$parsed.family] -eq $clean) { return $false }
    $script:State['claude_versions'][$parsed.family] = $clean
    return $true
}

function Get-AiPick([string]$Target) {
    $pick = @{ model = ''; effort = '' }
    if ($script:State) {
        $pick.model = [string]$script:State[$Target + '_model']
        $pick.effort = [string]$script:State[$Target + '_effort']
    }
    return $pick
}

function Get-CodexModels {
    # Codex lists its models with a priority; 1 is the newest recommended model.
    $home_ = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $list = @()
    try {
        $cache = Get-Content -LiteralPath (Join-Path $home_ 'models_cache.json') -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        foreach ($m in @($cache.models | Where-Object { $_.visibility -eq 'list' -and $_.slug -and $_.slug -notmatch 'review|auto' } |
                         Sort-Object { [int]$_.priority })) {
            $list += @{ slug = [string]$m.slug; name = [string]$m.display_name
                        levels = @($m.supported_reasoning_levels | ForEach-Object { [string]$_.effort }) }
        }
    } catch {}
    if (-not $list.Count) { $list = @(@{ slug = $script:CodexFallbackModel; name = 'GPT-6.2-Sol'; levels = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra') }) }
    return $list
}

function Get-DefaultEffort([string[]]$Levels) {
    if (-not $Levels.Count -or $Levels -contains $script:AiEffort) { return $script:AiEffort }
    return (@('high', 'medium', 'low') | Where-Object { $Levels -contains $_ } | Select-Object -First 1)
}

# Choices for the window. The recommended entry has id '' so it keeps following the newest model / default level.
function Get-AiModelOptions([string]$Target) {
    if ($Target -eq 'claude') {
        $options = @()
        foreach ($key in $script:ClaudeModels.Keys) {
            if ($key -eq 'fable') { $options += @{ id = ''; text = (Get-ClaudeModelName $key) + (L ' (권장)') } }
            else { $options += @{ id = $key; text = Get-ClaudeModelName $key } }
        }
        return $options
    }
    $models = @(Get-CodexModels)
    $options = @(@{ id = ''; text = $models[0].name + (L ' (권장)') })
    foreach ($m in ($models | Select-Object -Skip 1)) { $options += @{ id = $m.slug; text = $m.name } }
    return $options
}

function Get-AiEffortLevels([string]$Target, [string]$Model) {
    if ($Target -eq 'claude') { return $script:ClaudeEfforts }
    $models = @(Get-CodexModels)
    $chosen = @($models | Where-Object { $_.slug -eq $Model }) + @($models[0]) | Select-Object -First 1
    return @($chosen.levels)
}

function Get-AiEffortOptions([string]$Target, [string]$Model) {
    $levels = Get-AiEffortLevels $Target $Model
    $default = Get-DefaultEffort $levels
    $options = @()
    foreach ($level in $levels) {
        if ($level -eq $default) { $options += @{ id = ''; text = $level + (L ' (권장)') } }
        else { $options += @{ id = $level; text = $level } }
    }
    if (-not $options.Count) { $options = @(@{ id = ''; text = $default + (L ' (권장)') }) }
    return $options
}

function Get-AiModelChoice([string]$Target) {
    $pick = Get-AiPick $Target
    if ($Target -eq 'claude') {
        $model = if ($pick.model -and $script:ClaudeModels.Contains($pick.model)) { $pick.model } else { 'fable' }
        # If the chosen model is overloaded the next one down takes over.
        $fallback = switch ($model) { 'fable' { 'opus' } 'opus' { 'sonnet' } default { $null } }
        $effort = if ($pick.effort -and $script:ClaudeEfforts -contains $pick.effort) { $pick.effort } else { $script:AiEffort }
        $name = Get-ClaudeModelName $model
        return @{ model = $model; effort = $effort; fallback = $fallback; label = ($name + (L ' · 추론 ') + $effort) }
    }
    $models = @(Get-CodexModels)
    $chosen = @($models | Where-Object { $pick.model -and $_.slug -eq $pick.model }) + @($models[0]) | Select-Object -First 1
    $levels = @($chosen.levels)
    $effort = if ($pick.effort -and ($levels.Count -eq 0 -or $levels -contains $pick.effort)) { $pick.effort } else { Get-DefaultEffort $levels }
    return @{ model = $chosen.slug; effort = $effort; fallback = $null; label = ($chosen.name + (L ' · 추론 ') + $effort) }
}

function Find-AiCli([string]$Target) {
    $candidates = @()
    # Test hook: AE_AUTOSET_CLAUDE_EXE / AE_AUTOSET_CODEX_EXE point at a stand-in program.
    if ($env:AE_AUTOSET_TEST_NO_CLI) { return $null }
    $override = [Environment]::GetEnvironmentVariable('AE_AUTOSET_' + $Target.ToUpper() + '_EXE')
    if ($override) { $candidates += $override }
    if ($Target -eq 'claude') {
        $command = Get-Command claude.exe -ErrorAction SilentlyContinue
        if ($command) { $candidates += $command.Source }
        $candidates += Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    } else {
        foreach ($name in 'codex.exe', 'codex.cmd', 'codex') {
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if ($command -and $command.Source) { $candidates += $command.Source }
        }
        $candidates += Join-Path $env:LOCALAPPDATA 'Programs\OpenAI\Codex\bin\codex.exe'
        $candidates += Join-Path $env:APPDATA 'npm\codex.cmd'
        $candidates += Join-Path $env:USERPROFILE '.local\bin\codex.exe'
    }
    foreach ($path in $candidates) { if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path } }
    return $null
}

function Invoke-Quiet([string]$File, [string]$Arguments, [int]$TimeoutSeconds = 20) {
    if ($File -match '\.(cmd|bat)$') { $Arguments = '/d /s /c ""' + $File + '" ' + $Arguments + '"'; $File = $env:ComSpec }
    $info = New-Object Diagnostics.ProcessStartInfo($File, $Arguments)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch {}; return @{ code = -1; text = '' } }
    return @{ code = $process.ExitCode; text = ($output.Result + $errors.Result) }
}

# Login check that costs no usage. Returns $true, $false, or $null when it cannot tell.
function Test-AiLogin([string]$Target, [string]$Exe) {
    try {
        if ($Target -eq 'claude') { $result = Invoke-Quiet $Exe 'auth status' }
        else { $result = Invoke-Quiet $Exe 'login status' }
    } catch { return $null }
    if ($result.code -eq 0) { return $true }
    if ($result.code -eq 1) { return $false }
    return $null
}

function ConvertTo-PosixRulePath([string]$Path) {
    # Claude Code permission rules use //<drive>/<path> for absolute Windows paths.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^([A-Za-z]):\\?(.*)$') { return $null }
    return '//' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
}

function ConvertTo-ArgumentText([string[]]$Values) {
    # Windows command-line quoting (backslashes before quotes are doubled).
    ($Values | ForEach-Object {
        $value = [string]$_
        if ($value -notmatch '[\s"]' -and $value) { $value }
        else { '"' + ([regex]::Replace($value, '(\\*)("|$)', { param($m) $m.Groups[1].Value + $m.Groups[1].Value + $(if ($m.Groups[2].Value) { '\"' } else { '' }) })) + '"' }
    }) -join ' '
}

function New-AiPrompt([string]$Request, [string]$SkillRoot, [string]$Target) {
    $skill = Join-Path $SkillRoot 'SKILL.md'
    $invoke = Join-Path $SkillRoot 'scripts\Invoke-AutoSet.ps1'
    $state = Join-Path $SkillRoot 'scripts\Read-AutoSetState.ps1'
    $reworkMark = (L ' (기존 결과 재작업)').Trim()
    $reply = @{ ko = '한국어'; ja = '일본어(日本語)'; en = '영어(English)'; zh = '중국어 간체(简体中文)' }[$script:Lang]
    if (-not $reply) { $reply = '한국어' }
    return @"
이 작업은 AE AutoSet 설정 창의 "작업 시작" 버튼으로 시작된 무인 실행입니다. 실행 중에는 사용자가 대답할 수 없습니다.

1. 먼저 "$skill" 을 읽고, 그 SKILL.md와 거기서 안내하는 references 문서를 이 작업의 유일한 지침으로 따르세요.
   이 PC에 따로 설치된 ae-autoset / AE AutoSet 스킬(.agents\skills, .claude\skills 등)은 버전이 다르므로 읽거나 쓰지 마세요.
2. 처리할 요청: $Request
3. 실행 스크립트: "$invoke" (작업 단계), "$state" (진행 상태). 셸 명령은 이 두 스크립트만 허용되고, 각 명령은 따로 실행하세요(; 로 잇지 말 것). PowerShell 문법으로 실행하세요.
   - AE 결과를 기다릴 때는 Start-Sleep 대신 "$state" -SessionPath "<session.json>" -WaitSeconds 90 을 반복하세요.
   - Launch는 이번 작업 전용 After Effects를 따로 열고, 끝나면 그 AE가 스스로 닫힙니다. 작업자가 쓰던 AE는 닫거나 저장하지 마세요.
     새 AE가 뜨는 데 몇 분 걸릴 수 있으니 Launch 결과가 dispatched여도 다시 실행하지 말고 위 명령으로 기다리세요.
   - AE를 시작하기 전에 준비 실패 컷의 판독을 고쳤다면 "$invoke" -Action Prepare -SessionPath "<session.json>" -RetryFailed 로 그 컷만 다시 준비하세요.
   - 요청에 "$reworkMark"이 있으면 작업자가 재작업을 명시적으로 허락한 것입니다. Begin에 -Overwrite를 붙이세요(이전 결과는 _sessions에 보관됨).
4. 판독 결과와 카메라 결정 파일은 각 컷 폴더의 _timesheet_auto 안에만 씁니다.
5. 사람의 판단이 필요하면 스킬 규칙대로 그 컷만 멈추고 사유를 남긴 뒤 나머지 컷을 계속하세요. 질문으로 끝내지 마세요.
6. 끝나면 스킬의 보고 형식대로 $reply 로 짧게 결과를 정리하세요. 작업자에게 남기는 메모와 사유도 $reply 로 쓰세요.
"@
}

function Get-AiCommand([string]$Target, [string]$Exe, [string]$WorkRoot, [string]$SkillRoot) {
    $environment = New-Object 'System.Collections.Generic.Dictionary[string,string]'
    # The window's language, so the engine can write worker notes in it.
    if ($script:Lang) { $environment['AE_AUTOSET_LANG'] = $script:Lang }
    if ($Target -eq 'claude') {
        $workRule = ConvertTo-PosixRulePath $WorkRoot
        if (-not $workRule -or $workRule.Contains(',')) { throw (L '컷 폴더 경로에 쉼표(,)가 있으면 작업 시작을 쓸 수 없어요. 작업 요청 복사를 쓰세요.') }
        # Writes: only inside the work folder. Commands: a PreToolUse hook (PermissionHook.ps1) allows
        # exactly this skill's two scripts and short waits; everything else is denied by dontAsk mode.
        $hook = Join-Path $PSScriptRoot 'PermissionHook.ps1'
        $hookCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $hook + '"'
        $settings = @{ hooks = @{ PreToolUse = @(@{ matcher = 'PowerShell|Bash'; hooks = @(@{ type = 'command'; command = $hookCommand; timeout = 30 }) }) } }
        $settingsPath = Join-Path ([IO.Path]::GetTempPath()) 'ae-autoset-claude-settings.json'
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $choice = Get-AiModelChoice 'claude'
        $arguments = @('-p', '--output-format', 'stream-json', '--verbose', '--permission-mode', 'dontAsk',
                       '--model', $choice.model, '--effort', $choice.effort)
        if ($choice.fallback) { $arguments += @('--fallback-model', $choice.fallback) }
        $arguments += @('--settings', $settingsPath, '--add-dir', $SkillRoot, '--allowedTools', "Edit($workRule/**)")
        $environment['CLAUDE_CODE_USE_POWERSHELL_TOOL'] = '1'
        $environment['AE_AUTOSET_SKILL_ROOT'] = $SkillRoot
        return (New-ProgramCall $Exe $arguments $WorkRoot $environment)
    }
    # Codex: filled in by Get-CodexCommand when available.
    return (Get-CodexCommand $Exe $WorkRoot $SkillRoot $environment)
}

function Get-CodexCommand([string]$Exe, [string]$WorkRoot, [string]$SkillRoot, $Environment) {
    # Codex exec never asks for approval. Its sandbox would hide or stop After Effects and block writes
    # outside the folder, so it runs with full access; the window asks the worker before starting.
    $choice = Get-AiModelChoice 'codex'
    $arguments = @('exec', '--json', '--skip-git-repo-check', '--sandbox', 'danger-full-access',
                   '-m', $choice.model, '-c', ('model_reasoning_effort=' + $choice.effort), '-C', $WorkRoot, '-')
    return (New-ProgramCall $Exe $arguments $WorkRoot $Environment)
}

function New-ProgramCall([string]$Exe, [string[]]$Arguments, [string]$WorkRoot, $Environment) {
    $text = ConvertTo-ArgumentText $Arguments
    if ($Exe -match '\.(cmd|bat)$') { return @{ file = $env:ComSpec; arguments = ('/d /s /c ""' + $Exe + '" ' + $text + '"'); cwd = $WorkRoot; env = $Environment } }
    return @{ file = $Exe; arguments = $text; cwd = $WorkRoot; env = $Environment }
}

# ---------------------------------------------------------------- progress text

function Get-Leaf([string]$Path) { if ($Path) { ($Path -split '[\\/]')[-1] } else { '' } }

function Describe-Command([string]$Command) {
    $action = [regex]::Match($Command, '-Action\s+["'']?(\w+)')
    if ($Command -match 'Invoke-AutoSet\.ps1' -and $action.Success) {
        switch ($action.Groups[1].Value) {
            'Profile' { return (L '작업 대상 확인') }
            'Begin'   { return (L '작업 시작 · 시트·LO 미리보기 준비') }
            'Prepare' { return (L '판독 결과 검증 · AE 작업 준비') }
            'Launch'  { return (L 'After Effects에 적용 요청') }
            'Finish'  { return (L '저장 확인 · 마무리') }
            default   { return (L '엔진 {0}' $action.Groups[1].Value) }
        }
    }
    if ($Command -match 'Read-AutoSetState') { return (L '진행 상황 확인') }
    if ($Command -match '^\s*(Start-Sleep|sleep)\b') { return (L 'After Effects 작업 대기') }
    $short = ($Command -replace '\s+', ' ').Trim()
    if ($short.Length -gt 90) { $short = $short.Substring(0, 90) + '…' }
    return (L '명령 · {0}' $short)
}

function Describe-Tool([string]$Name, $InputData) {
    switch -Regex ($Name) {
        '^(Read|view_image)$' { return (L '보는 중 · {0}' (Get-Leaf ([string]$InputData.file_path + [string]$InputData.path))) }
        '^(Write|Edit|MultiEdit)$' { return (L '기록 작성 · {0}' (Get-Leaf ([string]$InputData.file_path))) }
        '^(PowerShell|Bash)$' { return Describe-Command ([string]$InputData.command) }
        '^(Glob|Grep|LS)$' { return (L '파일 찾는 중') }
        '^Skill$' { return (L '스킬 불러오는 중') }
        '^TodoWrite$' { return $null }
        default { return $Name }
    }
}

# Turns one output line into display lines. Updates $script:AiRun (session id, final text, error flag).
function ConvertFrom-AiLine([string]$Target, [string]$Raw) {
    $tag = $Raw.Substring(0, 1); $line = $Raw.Substring(1)
    if ($tag -eq 'E') {
        if ($line.Trim()) { $script:AiRun.stderr += $line }
        return @()
    }
    if (-not $line.Trim().StartsWith('{')) { return @() }
    try { $event = $line | ConvertFrom-Json } catch { return @() }
    $out = @()
    if ($Target -eq 'claude') {
        switch ([string]$event.type) {
            'system' {
                if ($event.subtype -eq 'init') {
                    $script:AiRun.session = [string]$event.session_id; $out += (L 'Claude Code 시작 · {0}' ([string]$event.model))
                    if (Save-ClaudeVersion ([string]$event.model)) { $script:AiRun.versionChanged = $true }
                }
                elseif ($event.subtype -eq 'api_retry') { $out += (L '연결 재시도 중…') }
            }
            'assistant' {
                foreach ($block in @($event.message.content)) {
                    if ($block.type -eq 'text' -and [string]$block.text) { $out += ('› ' + ([string]$block.text).Trim()) }
                    elseif ($block.type -eq 'tool_use') { $text = Describe-Tool ([string]$block.name) $block.input; if ($text) { $out += ('· ' + $text) } }
                }
            }
            'user' {
                foreach ($block in @($event.message.content)) {
                    if ($block.type -eq 'tool_result' -and $block.is_error) {
                        $detail = if ($block.content -is [string]) { $block.content } else { (@($block.content) | ForEach-Object { [string]$_.text }) -join ' ' }
                        $detail = ($detail -replace '\s+', ' ').Trim(); if ($detail.Length -gt 160) { $detail = $detail.Substring(0, 160) + '…' }
                        $out += ('! ' + $detail)
                    }
                }
            }
            'result' {
                $script:AiRun.done = $true
                $script:AiRun.isError = [bool]$event.is_error
                $script:AiRun.final = [string]$event.result
                $script:AiRun.session = [string]$event.session_id
                foreach ($denied in @($event.permission_denials)) { if ($denied) { $script:AiRun.denied += [string]$denied.tool_name } }
            }
        }
    } else {
        $out += ConvertFrom-CodexEvent $event
    }
    return $out
}

function ConvertFrom-CodexEvent($Event) {
    $out = @()
    $item = $Event.item
    switch -Regex ([string]$Event.type) {
        '^thread\.started$' { $script:AiRun.session = [string]$Event.thread_id; $out += (L 'Codex 시작') }
        '^item\.(started|completed)$' {
            switch ([string]$item.type) {
                'agent_message' { if ($Event.type -eq 'item.completed' -and [string]$item.text) { $script:AiRun.final = [string]$item.text; $out += ('› ' + ([string]$item.text).Trim()) } }
                'command_execution' {
                    if ($Event.type -eq 'item.started') { $out += ('· ' + (Describe-Command ([string]$item.command))) }
                    elseif ($item.exit_code -and [int]$item.exit_code -ne 0) { $out += (L '! 명령 실패 (코드 {0})' ([string]$item.exit_code)) }
                }
                'file_change' { if ($Event.type -eq 'item.completed') { foreach ($change in @($item.changes)) { $out += ('· ' + (L '기록 작성 · {0}' (Get-Leaf ([string]$change.path)))) } } }
                'error' { $out += ('! ' + [string]$item.message) }
            }
        }
        '^turn\.completed$' { $script:AiRun.done = $true }
        '^turn\.failed$' { $script:AiRun.done = $true; $script:AiRun.isError = $true; $out += ('! ' + [string]$Event.error.message) }
        '^error$' { $script:AiRun.isError = $true; $out += ('! ' + [string]$Event.message) }
    }
    return $out
}
