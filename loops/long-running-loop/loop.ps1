# long-running-loop: runs a long task as a loop of fresh Claude Code sessions.
#
# The Windows-native driver, in PowerShell 7: the same loop directory, files, settings
# and commands as loop.sh, with no bash, jq or tmux. Each round is a new,
# non-interactive `claude -p` session with an empty context. It reads the loop's files,
# does one bounded batch of work, commits, records what it did and ends with a status
# line; then the next round starts.
#
# A loop lives in a directory (default .\.loop) holding six files:
#   MEMORY.md    the few fundamental concepts every round must never forget (rarely changes)
#   PLAN.md      the work to do: goal, rules, gates, checklists (evolves slowly)
#   PROGRESS.md  the state: status, next actions, open questions, one log line per round
#   PROMPT.md    the prompt every round starts with ({{PLACEHOLDERS}} are filled in)
#   INBOX.md     your new instructions; the next round folds them into PLAN/PROGRESS
#   CLEANUP.md   what a short session cleans up after each round (optional)
# plus loop.conf (settings) and state\ (logs, lock, scratch; git-ignored).
#
# Usage: loop.ps1 [-d LOOP_DIR] COMMAND [ARGS]
#
#   init              create LOOP_DIR with the six files, loop.conf and state\
#   run               run the loop in this terminal (Ctrl-C kills the current round)
#   detach            run the loop in the background, in a hidden window of its own
#   stop [--now]      stop after the current round (--now: kill the round too)
#   status            running or not, the last rounds, cost
#   follow [--log]    live view: the loop log in colour and the round's last events
#   watch             stream the loop log and the running round's transcript in colour
#   commits [-r N] [-n N] [--once]
#                     the work tree's commits, grouped by round, refreshing
#   panes             a Windows Terminal tab with watch, follow and commits in three
#                     panes (`tmux` is an alias)
#   inbox [TEXT]      append a dated instruction to INBOX.md (no TEXT: open $env:EDITOR)
#   cleanup           run CLEANUP.md now, for the last round (not while the loop runs)
#   prompt [N]        print the prompt round N would get
#   config            print the effective settings
#
# Settings: LOOP_DIR\loop.conf (the shell assignments loop.sh reads), overridden by the
# environment. `loop.ps1 config` lists them all with their values. Requires PowerShell
# 7+, git and the claude CLI; Windows Terminal for `panes`.
#Requires -Version 7.0

$ErrorActionPreference = 'Continue'
$SELF = $PSCommandPath
$SKILL_DIR = Split-Path -Parent $SELF
$TEMPLATES = Join-Path $SKILL_DIR 'templates'
$INV = [Globalization.CultureInfo]::InvariantCulture
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.UTF8Encoding]::new($false)

function Show-Usage {
  foreach ($l in Get-Content -LiteralPath $SELF) {
    if ($l -notmatch '^#' -or $l -match '^#Requires') { break }
    $l -replace '^# ?', ''
  }
}

# ---------------------------------------------------------------- colours

$E = [char]27
if (-not $env:NO_COLOR -and -not [Console]::IsOutputRedirected) {
  $RST = "$E[0m"; $BOLD = "$E[1m"; $DIM = "$E[2m"; $RED = "$E[31m"; $GREEN = "$E[32m"
  $YELLOW = "$E[33m"; $BLUE = "$E[34m"; $MAGENTA = "$E[35m"; $CYAN = "$E[36m"
  $GRAY = "$E[90m"; $WHITE = "$E[37m"
} else {
  $RST = $BOLD = $DIM = $RED = $GREEN = $YELLOW = $BLUE = $MAGENTA = $CYAN = $GRAY = $WHITE = ''
}
function Die([string]$msg) { [Console]::Error.WriteLine("$RED$msg$RST"); exit 1 }
function Out-Line([string]$s) { [Console]::Out.WriteLine($s) }

# ---------------------------------------------------------------- arguments

$LOOP_DIR = $env:LOOP_DIR
$argv = @($args | ForEach-Object { [string]$_ })
$i = 0
while ($i -lt $argv.Count) {
  if ($argv[$i] -in '-d', '--dir') {
    if ($i + 1 -ge $argv.Count) { Die '-d needs a directory' }
    $LOOP_DIR = $argv[$i + 1]; $i += 2
  } elseif ($argv[$i] -in '-h', '--help', 'help') {
    Show-Usage; exit 0
  } else { break }
}
$CMD = if ($i -lt $argv.Count) { $argv[$i] } else { '' }
$CMD_ARGS = @(if ($i + 1 -lt $argv.Count) { $argv[($i + 1)..($argv.Count - 1)] })
if (-not $CMD) { Show-Usage; exit 2 }

function Get-FullPath([string]$p) {
  $p = [IO.Path]::GetFullPath($p, (Get-Location -PSProvider FileSystem).ProviderPath)
  if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }
  $p
}
if (-not $LOOP_DIR) { $LOOP_DIR = '.loop' }
$LOOP_DIR = Get-FullPath $LOOP_DIR
$ME = Split-Path -Leaf $SELF

# ---------------------------------------------------------------- init

if ($CMD -eq 'init') {
  if (-not (Test-Path -LiteralPath $TEMPLATES)) { Die "Templates not found in $TEMPLATES." }
  New-Item -ItemType Directory -Force -Path (Join-Path $LOOP_DIR 'state') | Out-Null
  foreach ($f in 'MEMORY.md', 'PLAN.md', 'PROGRESS.md', 'PROMPT.md', 'INBOX.md', 'CLEANUP.md', 'loop.conf') {
    $dst = Join-Path $LOOP_DIR $f
    if (Test-Path -LiteralPath $dst) { Out-Line "kept     $dst" }
    else { Copy-Item -LiteralPath (Join-Path $TEMPLATES $f) -Destination $dst; Out-Line "created  $dst" }
  }
  $gi = Join-Path $LOOP_DIR '.gitignore'
  if (-not (Test-Path -LiteralPath $gi)) { [IO.File]::WriteAllText($gi, "state/`n") }
  Out-Line @"

Next:
  0. Write in MEMORY.md only the few fundamental concepts no round may ever forget
     (or leave it empty); everything else goes in PLAN.md.
  1. Write PLAN.md (the goal, rules, gates and checklists) and the first "Now" items
     of PROGRESS.md. Ask Claude to draft them from your brief if you like.
  2. List in CLEANUP.md what every round must clean up at its end (or delete it).
  3. Adjust loop.conf (model, effort, limits, extra directories, environment).
  4. Commit the loop directory, then: $ME -d $LOOP_DIR detach
     and watch it with: $ME -d $LOOP_DIR panes
"@
  exit 0
}

if (-not (Test-Path -LiteralPath $LOOP_DIR -PathType Container)) {
  Die "No loop in $LOOP_DIR (create one with: $ME -d $LOOP_DIR init)."
}

# ---------------------------------------------------------------- settings

# loop.conf holds shell assignments (KEY=value, KEY="value", comments); values may use
# $VAR, ${VAR} and a leading ~. An environment variable wins over loop.conf.
$CONF = @{}
function Expand-ConfValue([string]$v) {
  if ($v -match '^~(?=$|[\\/])') { $v = $HOME + $v.Substring(1) }
  [regex]::Replace($v, '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', {
      param($m)
      $n = $m.Groups[1].Value
      $e = [Environment]::GetEnvironmentVariable($n)
      if ($null -ne $e) { $e } elseif ($n -eq 'HOME') { $HOME } elseif ($CONF.ContainsKey($n)) { $CONF[$n] } else { '' }
    })
}
$confFile = Join-Path $LOOP_DIR 'loop.conf'
if (Test-Path -LiteralPath $confFile) {
  foreach ($line in Get-Content -LiteralPath $confFile) {
    if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
    $name = $Matches[1]; $v = $Matches[2].Trim()
    if ($v -match '^"((?:[^"\\]|\\.)*)"') { $v = Expand-ConfValue ($Matches[1] -replace '\\(.)', '$1') }
    elseif ($v -match "^'([^']*)'") { $v = $Matches[1] }
    else { $v = Expand-ConfValue (($v -replace '\s+#.*$', '').Trim()) }
    $CONF[$name] = $v
  }
}
function Setting([string]$name, [string]$default = '') {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($null -eq $v) { $v = $CONF[$name] }
  if ([string]::IsNullOrEmpty($v)) { $default } else { $v }
}

$WORKDIR = Setting WORKDIR
if (-not $WORKDIR) {
  $WORKDIR = git -C $LOOP_DIR rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $WORKDIR) { $WORKDIR = Split-Path -Parent $LOOP_DIR }
}
$WORKDIR = Get-FullPath $WORKDIR
$NAME = Setting NAME (Split-Path -Leaf $WORKDIR)
$STATE_DIR = Get-FullPath (Setting STATE_DIR (Join-Path $LOOP_DIR 'state'))
$SCRATCH = Get-FullPath (Setting SCRATCH (Join-Path $STATE_DIR 'scratch'))
$CLAUDE_BIN = Setting CLAUDE_BIN 'claude'
$MODEL = Setting MODEL 'claude-opus-5-5'
$EFFORT = Setting EFFORT 'high'
$SUBAGENT_MODEL = Setting SUBAGENT_MODEL 'sonnet'
$PERMISSION_MODE = Setting PERMISSION_MODE 'auto'
$MAX_ROUNDS = [int](Setting MAX_ROUNDS 30)
$MAX_TURNS = [int](Setting MAX_TURNS 500)
$STALL_ROUNDS = [int](Setting STALL_ROUNDS 2)
$MAX_FAILURES = [int](Setting MAX_FAILURES 3)
$MAX_COST = Setting MAX_COST
$LIMIT_WAIT = [int](Setting LIMIT_WAIT 1800)
$TRANSIENT_WAIT = [int](Setting TRANSIENT_WAIT 300)
$CLASSIFIER_WAIT = [int](Setting CLASSIFIER_WAIT 600)
$CLEANUP_ENABLED = Setting CLEANUP_ENABLED 1
$CLEANUP_MODEL = Setting CLEANUP_MODEL 'claude-sonnet-5-5'
$CLEANUP_TURNS = Setting CLEANUP_TURNS 40
$ADD_DIRS = Setting ADD_DIRS
$EXPORT_ENV = Setting EXPORT_ENV
$EXTRA_ARGS = Setting EXTRA_ARGS
$GIT_NAME = Setting GIT_NAME
$GIT_EMAIL = Setting GIT_EMAIL
$NOTIFY = Setting NOTIFY 1
$KEEP_AWAKE = Setting KEEP_AWAKE 1
$FOLLOW_LINES = [int](Setting FOLLOW_LINES 10)
$FOLLOW_WIDTH = [int](Setting FOLLOW_WIDTH 2)
$FOLLOW_LOG = Setting FOLLOW_LOG
$WATCH_LINES = [int](Setting WATCH_LINES 40)
$WATCH_THINKING = Setting WATCH_THINKING 1
$COMMIT_ROUNDS = [int](Setting COMMIT_ROUNDS 3)
$COMMIT_COUNT = [int](Setting COMMIT_COUNT 40)
$EVERY = [double]::Parse((Setting EVERY 2), $INV)
$EVENT_TAIL = [int](Setting EVENT_TAIL 400)
$BASH_DEFAULT_TIMEOUT_MS = Setting BASH_DEFAULT_TIMEOUT_MS 3600000
$BASH_MAX_TIMEOUT_MS = Setting BASH_MAX_TIMEOUT_MS 7200000

$MEMORY = Join-Path $LOOP_DIR 'MEMORY.md'
$PLAN = Join-Path $LOOP_DIR 'PLAN.md'
$PROGRESS = Join-Path $LOOP_DIR 'PROGRESS.md'
$PROMPT = Join-Path $LOOP_DIR 'PROMPT.md'
$INBOX = Join-Path $LOOP_DIR 'INBOX.md'
$CLEANUP = Join-Path $LOOP_DIR 'CLEANUP.md'
$LOGS = Join-Path $STATE_DIR 'logs'
$SUMMARY = Join-Path $LOGS 'loop.log'
$LOCK = Join-Path $STATE_DIR 'loop.lock'
$STOP_FILE = Join-Path $STATE_DIR 'loop.stop'
New-Item -ItemType Directory -Force -Path $LOGS, (Join-Path $SCRATCH 'tmp') | Out-Null
if (-not (Test-Path -LiteralPath $SUMMARY)) { [IO.File]::WriteAllText($SUMMARY, '') }

# Claude Code keeps a project's transcripts under its path with every
# non-alphanumeric character replaced by a dash (C:\src\app -> C--src-app).
$CLAUDE_HOME = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$PROJECT_DIR = Join-Path $CLAUDE_HOME (Join-Path 'projects' ($WORKDIR -replace '[^A-Za-z0-9]', '-'))

# ---------------------------------------------------------------- helpers

# The pid in the lock when that process is still a PowerShell running the loop.
function Get-RunningPid {
  if (-not (Test-Path -LiteralPath $LOCK)) { return $null }
  $p = "$(Get-Content -LiteralPath $LOCK -Raw -ErrorAction SilentlyContinue)".Trim()
  if ($p -notmatch '^\d+$') { return $null }
  $proc = Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue
  if ($proc -and $proc.ProcessName -match '^(pwsh|powershell)$') { return [int]$p }
  $null
}

function G { git -C $WORKDIR --no-optional-locks @args }

$script:CanToast = $null
function Send-Notification([string]$text) {
  if ($NOTIFY -ne '1') { return }
  if ($null -eq $script:CanToast) {
    $script:CanToast = [bool](Get-Module -ListAvailable BurntToast -ErrorAction SilentlyContinue)
  }
  if ($script:CanToast) {
    try { New-BurntToastNotification -Text "Loop: $NAME", $text -ErrorAction Stop | Out-Null } catch { $script:CanToast = $false }
  }
}

# Colours one loop log line by what it says.
function Format-LogLine([string]$line) {
  $c = $RST
  if ($line -cmatch 'starting at') { $c = "$BOLD$CYAN" }
  elseif ($line -cmatch ' cleanup: ') { $c = if ($line -cmatch 'no CLEANUP line|exit [1-9]') { $YELLOW } else { $BOLD } }
  elseif ($line -cmatch 'ROUND: CONTINUE' -and $line -cnotmatch ' 0 commit') { $c = $GREEN }
  elseif ($line -cmatch 'ROUND: (CHECKPOINT|DONE)|Checkpoint|Done:') { $c = "$BOLD$GREEN" }
  elseif ($line -cmatch 'ROUND: BLOCKED|Blocked|in a row|without a commit|failed') { $c = "$BOLD$RED" }
  elseif ($line -cmatch 'no status line|exit [1-9]| 0 commit') { $c = $YELLOW }
  elseif ($line -cmatch '[Uu]sage limit|[Tt]ransient|retrying|safety check') { $c = $YELLOW }
  elseif ($line -cmatch 'Stopped|interrupted|Loop started|Reached') { $c = "$BOLD$MAGENTA" }
  if ($line -match '^(\[[^\]]*\])(.*)$') { "$DIM$($Matches[1])$RST$c$($Matches[2])$RST" } else { "$c$line$RST" }
}

function Say([string]$text) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'MM-dd HH:mm'), $text
  [IO.File]::AppendAllText($SUMMARY, "$line`n")
  Out-Line (Format-LogLine $line)
  Send-Notification $text
}

# Cuts a line to FOLLOW_WIDTH times the given width (0 keeps whole lines).
function Get-Clipped([string]$s, [int]$width) {
  $max = $width * $FOLLOW_WIDTH
  if ($FOLLOW_WIDTH -gt 0 -and $max -gt 0 -and $s.Length -gt $max) { $s.Substring(0, $max) } else { $s }
}

function Format-Money([double]$x) { $x.ToString('0.00', $INV) }

# The prompt of round $n (or the file $file, e.g. CLEANUP.md), placeholders filled in.
function Get-RenderedPrompt($n, [string]$file = $PROMPT) {
  $p = [IO.File]::ReadAllText($file)
  $branch = G rev-parse --abbrev-ref HEAD 2>$null
  if (-not $branch) { $branch = '?' }
  $map = [ordered]@{
    LOOP_DIR = $LOOP_DIR; WORKDIR = $WORKDIR; STATE_DIR = $STATE_DIR; SCRATCH = $SCRATCH
    MEMORY = $MEMORY; PLAN = $PLAN; PROGRESS = $PROGRESS; INBOX = $INBOX; CLEANUP = $CLEANUP
    ROUND = "$n"; MAX_ROUNDS = "$MAX_ROUNDS"; BRANCH = "$branch"; NAME = $NAME
  }
  foreach ($k in $map.Keys) { $p = $p.Replace("{{$k}}", [string]$map[$k]) }
  $p.TrimEnd("`r", "`n") + "`n"
}

# The first line of a file (at most 4000 bytes), read without locking it.
function Get-FirstLine([string]$path) {
  try {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
      $buf = [byte[]]::new(4000); $n = $fs.Read($buf, 0, $buf.Length)
      ([Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`n", 2)[0]
    } finally { $fs.Dispose() }
  } catch { '' }
}

# The transcripts of the newest round: the main one and its subagents'.
# Rounds are named "$NAME round N", which their transcript's first line
# records; other sessions in the same folder are skipped (the newest session
# is the fallback).
function Get-TranscriptFiles {
  if (-not (Test-Path -LiteralPath $PROJECT_DIR)) { return }
  $all = @(Get-ChildItem -LiteralPath $PROJECT_DIR -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTimeUtc -Descending)
  $sessions = @($all | Where-Object { $_.Name -notlike 'agent-*' })
  $main = $null
  foreach ($f in ($sessions | Select-Object -First 20)) {
    if ((Get-FirstLine $f.FullName).Contains("`"customTitle`":`"$NAME round ")) { $main = $f; break }
  }
  if (-not $main) { $main = $sessions | Select-Object -First 1 }
  if (-not $main) { return }
  $sid = $main.BaseName
  $main.FullName
  $sub = Join-Path (Join-Path $PROJECT_DIR $sid) 'subagents'
  if (Test-Path -LiteralPath $sub) {
    Get-ChildItem -LiteralPath $sub -Filter '*.jsonl' -File | Sort-Object Name | ForEach-Object { $_.FullName }
  }
  $since = (Get-Date).ToUniversalTime().AddMinutes(-240)
  foreach ($f in $all) {
    if ($f.Name -like 'agent-*' -and $f.LastWriteTimeUtc -gt $since -and
        (Get-FirstLine $f.FullName).Contains("`"sessionId`":`"$sid`"")) { $f.FullName }
  }
}

function ConvertFrom-JsonLine([string]$line) {
  if (-not $line.StartsWith('{')) { return $null }
  try { ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { $null }
}

function Get-Seconds($t) {
  if ($t -is [datetime]) { return [DateTimeOffset]::new($t.ToUniversalTime()).ToUnixTimeSeconds() }
  if ($t -is [string] -and $t) {
    try { return [DateTimeOffset]::Parse($t, $INV).ToUnixTimeSeconds() } catch { }
  }
  $null
}
function Get-Hms($secs) {
  if ($null -eq $secs) { return '--:--:--' }
  [DateTimeOffset]::FromUnixTimeSeconds($secs).ToLocalTime().ToString('HH:mm:ss')
}
function Get-ToolInput($in) {
  foreach ($k in 'command', 'file_path', 'pattern', 'description', 'prompt') {
    if ($in -and $in.$k) { return [string]$in.$k }
  }
  ''
}
function Get-ResultText($content) {
  if ($content -is [string]) { return $content }
  if ($content -is [array]) {
    return (@($content | Where-Object { $_ -and $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n")
  }
  if ($null -eq $content) { '' } else { [string]$content }
}

# Transcript events, sorted: key, time, kind, text. The key (timestamp|uuid|index)
# orders and deduplicates them.
function Get-Events([bool]$think) {
  $rows = foreach ($f in @(Get-TranscriptFiles)) {
    foreach ($line in @(Get-Content -LiteralPath $f -Tail $EVENT_TAIL -ErrorAction SilentlyContinue)) {
      $l = ConvertFrom-JsonLine $line
      if (-not $l -or $l.type -notin 'assistant', 'user') { continue }
      $ts = if ($l.timestamp -is [datetime]) { $l.timestamp.ToUniversalTime().ToString('o') } else { [string]$l.timestamp }
      $h = Get-Hms (Get-Seconds $l.timestamp)
      $s = if ($l.isSidechain) { 'sub ' } else { '' }
      $content = @($l.message.content)
      for ($k = 0; $k -lt $content.Count; $k++) {
        $b = $content[$k]
        if ($b -is [string] -or -not $b.type) { continue }
        $key = "$ts|$($l.uuid)|$k"
        $kind = $null; $text = $null
        if ($l.type -eq 'assistant') {
          if ($b.type -eq 'text') { $kind = "${s}say"; $text = $b.text }
          elseif ($b.type -eq 'tool_use') { $kind = "${s}tool"; $text = "$($b.name) $(Get-ToolInput $b.input)" }
          elseif ($b.type -eq 'thinking' -and $think) { $kind = "${s}think"; $text = $b.thinking }
        } elseif ($b.type -eq 'tool_result') {
          $kind = if ($b.is_error) { "${s}error" } else { "${s}done" }
          $text = if ($b.content -is [array]) { (@($b.content | ForEach-Object { $_.text }) -join ' ') } else { [string]$b.content }
        }
        if ($kind) { [pscustomobject]@{ Key = $key; Hms = $h; Kind = $kind; Text = ([string]$text -replace '[\n\t\r]', ' ') } }
      }
    }
  }
  $rows | Sort-Object -Property Key -Unique
}

# Events as coloured lines, cut to the given width.
function Format-Events([int]$width) {
  process {
    $c = switch -Wildcard ($_.Kind) { '*say' { $GREEN } '*tool' { $YELLOW } '*error' { $RED } default { $DIM } }
    '{0}{1}{2} {3}{4,-9}{5} {6}' -f $DIM, $_.Hms, $RST, $c, $_.Kind, $RST, (Get-Clipped $_.Text $width)
  }
}

# Stops a process and all its descendants, parents first.
function Stop-ProcessTree([int]$root) {
  $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
  $tree = [Collections.Generic.List[int]]::new(); $tree.Add($root)
  for ($k = 0; $k -lt $tree.Count; $k++) {
    foreach ($p in $procs) { if ($p.ParentProcessId -eq $tree[$k] -and $p.ProcessId -ne $root -and -not $tree.Contains([int]$p.ProcessId)) { $tree.Add([int]$p.ProcessId) } }
  }
  foreach ($id in $tree) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- run

# Runs one claude session in the work tree, the prompt on its stdin, its JSON
# output in $log and its stderr next to it. Returns the exit code.
function Invoke-Session([string]$prompt, [string]$log, [string[]]$sessionArgs) {
  $err = [IO.Path]::ChangeExtension($log, '.stderr')
  Push-Location -LiteralPath $WORKDIR
  try {
    $prompt | & $CLAUDE_BIN -p @sessionArgs > $log 2> $err
    $LASTEXITCODE
  } finally { Pop-Location }
}

function Read-Json([string]$path) {
  try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

function Get-LogPath([string]$kind, [int]$n) { Join-Path $LOGS ('{0}-{1:000}.json' -f $kind, $n) }
function Get-NextRound { $n = 1; while (Test-Path -LiteralPath (Get-LogPath 'round' $n)) { $n++ }; $n }

function Get-AddDirArgs {
  $a = @('--add-dir', $LOOP_DIR)
  if (-not $SCRATCH.StartsWith("$WORKDIR\", [StringComparison]::OrdinalIgnoreCase)) { $a += '--add-dir', $SCRATCH }
  foreach ($d in ($ADD_DIRS -split '\s+' | Where-Object { $_ })) { $a += '--add-dir', $d }
  $a
}

# After a round that ended with its status line, a short session follows
# CLEANUP.md to remove what the round left behind (processes, temp files, stale
# build outputs) and reports one `CLEANUP:` line, which goes to the loop log. A
# round that died or was interrupted keeps its leftovers, for a look.
function Invoke-Cleanup([int]$n) {
  if ($CLEANUP_ENABLED -ne '1' -or -not (Test-Path -LiteralPath $CLEANUP)) { return }
  $log = Get-LogPath 'cleanup' $n
  $cargs = @('--model', $CLEANUP_MODEL, '--permission-mode', $PERMISSION_MODE,
    '--output-format', 'json', '--max-turns', $CLEANUP_TURNS) + (Get-AddDirArgs) + @('--name', "$NAME cleanup $n")
  $code = Invoke-Session (Get-RenderedPrompt $n $CLEANUP) $log $cargs
  $r = Read-Json $log
  $script:TotalCost += [double]($r.total_cost_usd ?? 0)
  $out = @("$($r.result)" -split "`r?`n" | Where-Object { $_ -match '^CLEANUP: ' }) | Select-Object -Last 1
  Say "Round $n cleanup: $(if ($out) { $out } else { "no CLEANUP line (exit $code), see $log" })."
}

function Set-RoundEnvironment {
  $tmp = Join-Path $SCRATCH 'tmp'
  $env:TMPDIR = $tmp; $env:TMP = $tmp; $env:TEMP = $tmp
  $env:BASH_DEFAULT_TIMEOUT_MS = $BASH_DEFAULT_TIMEOUT_MS
  $env:BASH_MAX_TIMEOUT_MS = $BASH_MAX_TIMEOUT_MS
  if (-not $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS) { $env:CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS = '0' }
  $env:CLAUDE_CODE_SUBAGENT_MODEL = $SUBAGENT_MODEL
  if ($GIT_NAME) { $env:GIT_AUTHOR_NAME = $GIT_NAME; $env:GIT_COMMITTER_NAME = $GIT_NAME }
  if ($GIT_EMAIL) { $env:GIT_AUTHOR_EMAIL = $GIT_EMAIL; $env:GIT_COMMITTER_EMAIL = $GIT_EMAIL }
  foreach ($kv in ($EXPORT_ENV -split '\s+' | Where-Object { $_ -match '=' })) {
    $k, $v = $kv -split '=', 2
    [Environment]::SetEnvironmentVariable($k, $v)
  }
}

# Keeps Windows from sleeping while this thread (the loop) lives.
function Enable-KeepAwake {
  if ($KEEP_AWAKE -ne '1') { return }
  try {
    if (-not ('LoopNative.Power' -as [type])) {
      Add-Type -Namespace LoopNative -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);'
    }
    [LoopNative.Power]::SetThreadExecutionState([uint32]2147483649) | Out-Null  # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
  } catch { }
}

function Stop-Loop([int]$code) { $script:EndedCleanly = $true; exit $code }

function Start-Loop {
  if (-not (Get-Command $CLAUDE_BIN -ErrorAction SilentlyContinue)) { Die "The claude CLI ($CLAUDE_BIN) is not on PATH." }
  foreach ($f in $PLAN, $PROGRESS, $PROMPT) { if (-not (Test-Path -LiteralPath $f)) { Die "Missing $f (run init)." } }
  if (-not (Test-Path -LiteralPath $INBOX)) { [IO.File]::WriteAllText($INBOX, "# Inbox`n") }
  $running = Get-RunningPid
  if ($running) { Die "The loop is already running (pid $running)." }
  [IO.File]::WriteAllText($LOCK, "$PID")
  Remove-Item -LiteralPath $STOP_FILE -ErrorAction SilentlyContinue

  Set-RoundEnvironment
  Enable-KeepAwake
  $base = @('--model', $MODEL, '--effort', $EFFORT, '--permission-mode', $PERMISSION_MODE, '--output-format', 'json')
  if ($MAX_TURNS -gt 0) { $base += '--max-turns', "$MAX_TURNS" }
  $base += Get-AddDirArgs
  $extra = @($EXTRA_ARGS -split '\s+' | Where-Object { $_ })

  $script:TotalCost = 0.0
  $script:EndedCleanly = $false
  $stalls = 0; $failures = 0; $rounds = 0
  try {
    Say "Loop started in $WORKDIR ($MODEL, effort $EFFORT, at most $MAX_ROUNDS rounds)."
    while ($rounds -lt $MAX_ROUNDS) {
      if (Test-Path -LiteralPath $STOP_FILE) { Say 'Stopped on request.'; Remove-Item -LiteralPath $STOP_FILE; Stop-Loop 0 }
      $n = Get-NextRound
      $log = Get-LogPath 'round' $n
      $before = G rev-parse HEAD 2>$null; if (-not $before) { $before = 'none' }
      $at = G log -1 --format=%h 2>$null; if (-not $at) { $at = 'none' }
      Say "Round $n starting at $at."
      $code = Invoke-Session (Get-RenderedPrompt $n) $log ($base + @('--name', "$NAME round $n") + $extra)

      $r = Read-Json $log
      $result = "$($r.result)"
      $isError = [bool]$r.is_error
      $cost = [double]($r.total_cost_usd ?? 0)
      $turns = [int]($r.num_turns ?? 0)
      $errors = (@($r.errors) | Where-Object { $_ }) -join "`n"
      $script:TotalCost += $cost
      $commits = 0
      if ($before -ne 'none') { $c = G rev-list --count "$before..HEAD" 2>$null; if ($c) { $commits = [int]$c } }
      $status = @($result -split "`r?`n" | Where-Object { $_ -match '^ROUND: ' }) | Select-Object -Last 1
      Say ("Round $n ended: exit $code, $turns turns, `$$(Format-Money $cost) (total `$$(Format-Money $script:TotalCost)), " +
        "$commits commit(s), $(if ($status) { $status } else { 'no status line' }).")
      if ($status) { Invoke-Cleanup $n }

      # Waits that don't count as a round: usage limit, lost safety classifier
      # (auto mode), transient API errors before any work.
      $stderrTail = ''
      $errFile = [IO.Path]::ChangeExtension($log, '.stderr')
      if (Test-Path -LiteralPath $errFile) {
        $stderrTail = [IO.File]::ReadAllText($errFile); if ($stderrTail.Length -gt 2000) { $stderrTail = $stderrTail.Substring($stderrTail.Length - 2000) }
      }
      $text = "$result $errors $stderrTail"
      $waitS = 0
      if (-not $status -and $text -match 'usage limit|rate limit|hit your limit|limit reached|resets? (at|in)') {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $reset = if ($text -match '\|(\d{9,})') { [long]$Matches[1] } else { 0 }
        $waitS = if ($reset -gt $now) { [int]($reset - $now + 120) } else { $LIMIT_WAIT }
        Say "Usage limit: waiting $([int][math]::Floor($waitS / 60)) min, then retrying."
      } elseif ($errors -match 'auto mode is unavailable|no safety verdict') {
        $waitS = $CLASSIFIER_WAIT
        Say "Auto mode's safety check is unavailable (server side); retrying in $([int][math]::Floor($waitS / 60)) min."
      } elseif (-not $status -and $commits -eq 0 -and $turns -le 2 -and $text -match 'API Error: 5[0-9][0-9]|overloaded') {
        $waitS = $TRANSIENT_WAIT
        Say "Transient API error; retrying in $([int][math]::Floor($waitS / 60)) min."
      }
      if ($waitS -gt 0) {
        for ($slept = 0; $slept -lt $waitS; $slept += 30) {
          if (Test-Path -LiteralPath $STOP_FILE) { Say 'Stopped on request.'; Remove-Item -LiteralPath $STOP_FILE; Stop-Loop 0 }
          Start-Sleep -Seconds 30
        }
        continue
      }

      $rounds++
      if ($code -ne 0 -or $isError -or -not $result) {
        $failures++
        if ($failures -ge $MAX_FAILURES) { Say "$MAX_FAILURES failed rounds in a row; see $LOGS."; Stop-Loop 4 }
      } else { $failures = 0 }
      if ($commits -eq 0) { $stalls++ } else { $stalls = 0 }
      if ($stalls -ge $STALL_ROUNDS) { Say "$STALL_ROUNDS rounds without a commit; stopping for a look."; Stop-Loop 5 }
      if ($MAX_COST -and $script:TotalCost -ge [double]::Parse($MAX_COST, $INV)) {
        Say "Reached MAX_COST (`$$(Format-Money $script:TotalCost))."; Stop-Loop 6
      }
      if ($status -like 'ROUND: CHECKPOINT*') { Say 'Checkpoint reached: review PROGRESS.md, then rerun to continue.'; Stop-Loop 0 }
      if ($status -like 'ROUND: BLOCKED*') { Say "Blocked: $($status -replace '^ROUND: BLOCKED ?', '')"; Stop-Loop 3 }
      if ($status -like 'ROUND: DONE*') { Say 'Done: the plan is complete.'; Stop-Loop 0 }
    }
    Say "Reached MAX_ROUNDS ($MAX_ROUNDS); rerun to continue."
    $script:EndedCleanly = $true
  } finally {
    # Ctrl-C lands here too; the round's claude got it as well.
    if (-not $script:EndedCleanly) { Say 'Loop interrupted.' }
    Remove-Item -LiteralPath $LOCK -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------------- views

function Show-Status([int]$lines = 15) {
  $p = Get-RunningPid
  if ($p) { Out-Line "${GREEN}Running$RST (pid $p) in $WORKDIR" } else { Out-Line "${YELLOW}Not running.$RST ($WORKDIR)" }
  if (Test-Path -LiteralPath $STOP_FILE) { Out-Line "${MAGENTA}Stop requested after the current round.$RST" }
  Get-Content -LiteralPath $SUMMARY -Tail $lines | ForEach-Object { Out-Line (Format-LogLine $_) }
}

function Get-FollowFrame([int]$cols, [string]$running) {
  $last = Get-Content -LiteralPath $SUMMARY -Tail 1
  $rows = try { [Console]::WindowHeight } catch { 30 }
  $logn = if ($FOLLOW_LOG) { [int]$FOLLOW_LOG } else { $rows - 4 - $FOLLOW_LINES }
  if ($logn -lt 3) { $logn = 3 }
  "$BOLD${NAME}: $running$RST  $DIM($(Get-Date -Format 'HH:mm:ss'), Ctrl-C quits the view only)$RST"
  ''
  Get-Content -LiteralPath $SUMMARY -Tail $logn | ForEach-Object { Format-LogLine (Get-Clipped $_ $cols) }
  if ($FOLLOW_LINES -gt 0 -and "$last" -like '*starting at*') {
    Get-Events $false | Select-Object -Last $FOLLOW_LINES | Format-Events ($cols - 20) | ForEach-Object { "  $DIM│$RST $_" }
  }
}

function Show-Follow {
  if ($CMD_ARGS -contains '--log') { $script:FOLLOW_LINES = 0 }
  [Console]::Write("$E[?25l$E[2J")
  try {
    while ($true) {
      $cols = try { [Console]::WindowWidth } catch { 120 }
      $p = Get-RunningPid
      $running = if ($p) { "running (pid $p)" } else { 'not running' }
      if (Test-Path -LiteralPath $STOP_FILE) { $running += ', stop requested' }
      $frame = @(Get-FollowFrame $cols $running) -join "$E[K`n"
      [Console]::Write("$E[H$frame$E[K`n$E[J")
      Start-Sleep -Seconds $EVERY
    }
  } finally { [Console]::Write("$E[?25h`n") }
}

# Reads the complete lines appended to a file since byte $pos. Returns the new
# position and the lines.
function Read-Appended([string]$path, [long]$pos) {
  $res = @{ Pos = $pos; Lines = @() }
  try { $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete') } catch { return $res }
  try {
    if ($fs.Length -lt $pos) { $pos = 0 }
    $len = $fs.Length - $pos
    if ($len -le 0) { return $res }
    [void]$fs.Seek($pos, 'Begin')
    $buf = [byte[]]::new($len); $read = 0
    while ($read -lt $len) { $k = $fs.Read($buf, $read, $len - $read); if ($k -le 0) { break }; $read += $k }
    $end = $read - 1
    while ($end -ge 0 -and $buf[$end] -ne 10) { $end-- }
    if ($end -lt 0) { return $res }
    $res.Pos = $pos + $end + 1
    $res.Lines = @([Text.Encoding]::UTF8.GetString($buf, 0, $end + 1) -split "`r?`n" | Where-Object { $_ })
    $res
  } finally { $fs.Dispose() }
}

function Format-Colour([string]$code, [string]$s) { if ($RST) { "$E[${code}m$s$E[0m" } else { $s } }
function Get-OneLine([string]$s, [int]$max) { $s = $s -replace "`r?`n", ' ⏎ '; if ($s.Length -gt $max) { $s.Substring(0, $max) } else { $s } }

# One coloured line per transcript event, each shown once (deduplicated by
# uuid). Thinking in dark grey, messages in green, tool calls in yellow with
# their input in cyan, results dimmed with their duration and first lines,
# errors in red; subagents' lines are marked [sub].
function Format-WatchLines([string]$line) {
  $l = ConvertFrom-JsonLine $line
  if (-not $l -or $l.type -notin 'assistant', 'user') { return }
  if ($l.uuid) { if (-not $script:Seen.Add([string]$l.uuid)) { return } }
  $now = Get-Seconds $l.timestamp
  $ts = (Get-Hms $now) + $(if ($l.isSidechain) { ' [sub]' } else { '' })
  foreach ($b in @($l.message.content)) {
    if ($b -is [string] -or -not $b.type) { continue }
    if ($l.type -eq 'assistant') {
      if ($b.type -eq 'thinking') {
        if ($script:WatchThink) { Format-Colour '2;90' "$ts [think] $(Get-OneLine $b.thinking 300)" }
      } elseif ($b.type -eq 'text') {
        Format-Colour '32' "$ts [say]   $($b.text)"
      } elseif ($b.type -eq 'tool_use') {
        $script:Started[[string]$b.id] = $now
        $bg = if ($b.input.run_in_background) { ' (bg)' } else { '' }
        (Format-Colour '1;33' "$ts [tool]  $($b.name)$bg") + '  ' + (Format-Colour '36' (Get-OneLine (Get-ToolInput $b.input) 220))
      }
    } elseif ($b.type -eq 'tool_result') {
      $t0 = $script:Started[[string]$b.tool_use_id]
      $dur = if ($null -ne $t0 -and $null -ne $now) { " $([math]::Floor($now - $t0))s" } else { '' }
      $lines = @((Get-ResultText $b.content) -split "`n" | Where-Object { $_ })
      $more = if ($lines.Count -gt 2) { "  … +$($lines.Count - 2) lines" } else { '' }
      $first = Get-OneLine (($lines | Select-Object -First 2) -join "`n") 220
      Format-Colour $(if ($b.is_error) { '31' } else { '2;37' }) "$ts [done]$dur  $first$more"
      $script:Started.Remove([string]$b.tool_use_id)
    }
  }
}

# Streams the loop in real time: the loop log's new lines in bold magenta and
# the running round's transcript (messages, tool calls, results, subagents),
# switching to each new round's session by itself.
function Show-Watch {
  $script:WatchThink = $WATCH_THINKING -eq '1'
  $script:Seen = [Collections.Generic.HashSet[string]]::new()
  $script:Started = @{}
  if (-not (Test-Path -LiteralPath $PROJECT_DIR)) { Out-Line "No transcripts yet in $PROJECT_DIR (waiting for the first round)." }
  Show-Status 6; Out-Line ''
  $logPos = (Get-Item -LiteralPath $SUMMARY).Length
  $current = $null; $pos = @{}
  while ($true) {
    $r = Read-Appended $SUMMARY $logPos; $logPos = $r.Pos
    foreach ($l in $r.Lines) { Out-Line "$BOLD$MAGENTA$l$RST" }
    $files = @(Get-TranscriptFiles)
    if ($files.Count -gt 0) {
      if ($files[0] -ne $current) {
        $current = $files[0]; $pos = @{}; $script:Seen.Clear(); $script:Started.Clear()
        Out-Line "$BOLD$MAGENTA=== following $(Split-Path -Leaf $current) ===$RST"
        # The files' last lines first, then what they append.
        foreach ($f in $files) {
          $pos[$f] = (Get-Item -LiteralPath $f).Length
          foreach ($l in @(Get-Content -LiteralPath $f -Tail $WATCH_LINES -ErrorAction SilentlyContinue)) { Format-WatchLines $l | ForEach-Object { Out-Line $_ } }
        }
      }
      # A subagent started: its file from its first line.
      foreach ($f in $files) { if (-not $pos.ContainsKey($f)) { $pos[$f] = 0 } }
      foreach ($f in @($pos.Keys)) {
        $r = Read-Appended $f $pos[$f]; $pos[$f] = $r.Pos
        foreach ($l in $r.Lines) { Format-WatchLines $l | ForEach-Object { Out-Line $_ } }
      }
    }
    Start-Sleep -Seconds $EVERY
  }
}

function Get-Short([long]$n) {
  if ($n -lt 1000) { return "$n" }
  if ($n -lt 10000) { return ($n / 1000).ToString('0.0', $INV) + 'k' }
  "$([math]::Floor($n / 1000))k"
}
function Get-Ago([long]$s) {
  if ($s -lt 60) { return 'just now' }
  if ($s -lt 3600) { return "$([math]::Floor($s / 60))m ago" }
  if ($s -lt 86400) { return "$([math]::Floor($s / 3600))h ago" }
  "$([math]::Floor($s / 86400))d ago"
}

# One line per commit of a range: hash, age, size, subject.
function Get-CommitLines([int]$count, [string]$range) {
  $raw = (G log --no-merges --reverse -n $count '--format=%x1e%h%x1f%ct%x1f%s' --shortstat $range 2>$null) -join "`n"
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  foreach ($rec in ($raw -split [char]0x1e)) {
    $f = $rec -split [char]0x1f
    if ($f.Count -lt 3) { continue }
    $subject = ($f[2] -split "`n")[0]
    $files = if ($rec -match '(\d+) files? changed') { [long]$Matches[1] } else { 0 }
    $ins = if ($rec -match '(\d+) insertions?') { [long]$Matches[1] } else { 0 }
    $del = if ($rec -match '(\d+) deletions?') { [long]$Matches[1] } else { 0 }
    # <sha> <age> (<files>/<added>/<removed>) <message>
    "  $YELLOW$($f[0])$RST $BLUE$(Get-Ago ($now - [long]$f[1]))$RST ($GRAY${files}f$RST/$GREEN+$(Get-Short $ins)$RST/$RED-$(Get-Short $del)$RST) $WHITE$subject$RST"
  }
}

# Oldest first, so the newest commits are at the bottom, where the eye (and a short
# pane) ends up.
function Get-CommitsFrame([int]$rounds, [int]$count) {
  $branch = G rev-parse --abbrev-ref HEAD 2>$null
  $head = G log -1 '--format=%h %ar' 2>$null
  $dirty = @(G status --porcelain 2>$null).Count
  "$BOLD$(Get-Date -Format 'HH:mm:ss')  $branch  HEAD $head  $dirty uncommitted$RST"
  $last = "$(Get-Content -LiteralPath $SUMMARY -Tail 1)"
  "${MAGENTA}loop: $(if ($last.Length -gt 110) { $last.Substring(0, 110) } else { $last })$RST"
  ''
  $starts = @{}
  foreach ($l in Get-Content -LiteralPath $SUMMARY) {
    if ($l -match 'Round (\d+) starting at ([0-9a-f]*)\.') { $starts[$Matches[1]] = $Matches[2] }
  }
  if ($starts.Count -eq 0) { Get-CommitLines $count 'HEAD'; return }
  $order = @($starts.Keys | Sort-Object { [int]$_ })
  # Walk the rounds newest first (each one ends where the next starts), stacking
  # each block above the previous ones.
  $upper = 'HEAD'; $shown = 0; $blocks = [Collections.Generic.List[object]]::new()
  foreach ($n in ($order | Sort-Object { [int]$_ } -Descending)) {
    if ($rounds -gt 0 -and $shown -ge $rounds) { break }
    $shown++
    $start = $starts[$n]
    $out = @(Get-CommitLines $count "$start..$upper")
    $label = if ($upper -eq 'HEAD') { "round $n (latest)" } else { "round $n" }
    $block = @("$MAGENTA── $label, from $start ──$RST")
    $block += if ($out.Count) { $out } else { "  $DIM(no commit)$RST" }
    $blocks.Insert(0, $block)
    $upper = $start
  }
  if ($rounds -eq 0 -or $rounds -ge $order.Count) {
    $oldest = $starts[$order[0]]
    $blocks.Insert(0, @("$MAGENTA── before the loop ──$RST") + @(Get-CommitLines 12 $oldest))
  }
  foreach ($b in $blocks) { $b }
}

function Show-Commits {
  $rounds = 0; $count = $COMMIT_COUNT; $once = $false
  for ($k = 0; $k -lt $CMD_ARGS.Count; $k++) {
    switch ($CMD_ARGS[$k]) {
      '-r' { $k++; if ($k -ge $CMD_ARGS.Count) { Die '-r needs a number' }; $rounds = [int]$CMD_ARGS[$k] }
      '-n' { $k++; if ($k -ge $CMD_ARGS.Count) { Die '-n needs a number' }; $count = [int]$CMD_ARGS[$k] }
      '--once' { $once = $true }
      default { Die "commits: unknown option $_" }
    }
  }
  if ($once) { Get-CommitsFrame $rounds $count | ForEach-Object { Out-Line $_ }; return }
  [Console]::Write("$E[?25l")
  try {
    while ($true) {
      $frame = @(Get-CommitsFrame $rounds $count) -join "`n"
      [Console]::Write("$E[H$E[2J$frame`n")
      Start-Sleep -Seconds ($EVERY * 5)
    }
  } finally { [Console]::Write("$E[?25h") }
}

# A Windows Terminal tab: watch on the left, follow (log only) top right,
# commits bottom right. Each pane keeps a prompt after Ctrl-C to rerun its view.
function Open-Panes {
  if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Die "Windows Terminal (wt.exe) is needed for panes; run watch, follow and commits in three terminals instead."
  }
  $shell = (Get-Process -Id $PID).Path
  $view = { param($rest) @($shell, '-NoLogo', '-NoExit', '-File', $SELF, '-d', $LOOP_DIR) + $rest }
  $wtArgs = @('-w', '0', 'new-tab', '--title', "loop: $NAME", '-d', $WORKDIR) + (& $view @('watch')) +
    @(';', 'split-pane', '-V', '-s', '0.45', '-d', $WORKDIR) + (& $view @('follow', '--log')) +
    @(';', 'split-pane', '-H', '-s', '0.5', '-d', $WORKDIR) + (& $view @('commits', '-r', "$COMMIT_ROUNDS")) +
    @(';', 'move-focus', 'first')
  & wt.exe @wtArgs
}

# ---------------------------------------------------------------- commands

switch ($CMD) {
  { $_ -in 'run', 'start' } { Start-Loop }
  'detach' {
    $p = Get-RunningPid
    if ($p) { Out-Line "The loop is already running (pid $p)."; exit 0 }
    $shell = (Get-Process -Id $PID).Path
    $out = Join-Path $LOGS 'detached.out'
    Start-Process -FilePath $shell -WindowStyle Hidden -WorkingDirectory $WORKDIR `
      -RedirectStandardOutput $out -RedirectStandardError "$out.err" `
      -ArgumentList "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$SELF`" -d `"$LOOP_DIR`" run"
    Start-Sleep -Seconds 2
    $p = Get-RunningPid
    if ($p) { Out-Line "${GREEN}Loop started$RST in the background (pid $p). Watch: follow, watch or panes. Stop: stop." }
    else { Die "The loop didn't start; see $out." }
  }
  'stop' {
    if ($CMD_ARGS -contains '--now') {
      $p = Get-RunningPid
      if ($p) {
        Stop-ProcessTree $p
        Remove-Item -LiteralPath $LOCK -ErrorAction SilentlyContinue
        Say 'Loop interrupted.'
        Out-Line "Stopped the loop and its round (pid $p)."
      } else { Out-Line 'Not running.' }
    } else {
      [IO.File]::WriteAllText($STOP_FILE, '')
      Out-Line "${MAGENTA}The loop stops after the current round$RST (delete $STOP_FILE to cancel)."
    }
  }
  'status' { Show-Status 15 }
  'follow' { Show-Follow }
  'watch' { Show-Watch }
  'commits' { Show-Commits }
  { $_ -in 'panes', 'tmux' } { Open-Panes }
  'inbox' {
    if (-not (Test-Path -LiteralPath $INBOX)) { [IO.File]::WriteAllText($INBOX, "# Inbox`n") }
    if ($CMD_ARGS.Count -gt 0) {
      [IO.File]::AppendAllText($INBOX, "`n- $(Get-Date -Format 'yyyy-MM-dd HH:mm'): $($CMD_ARGS -join ' ')`n")
      Out-Line "Added to $INBOX; the next round takes it in."
    } else {
      $editor = if ($env:EDITOR) { $env:EDITOR } else { 'notepad.exe' }
      & $editor $INBOX
    }
  }
  'cleanup' {
    $p = Get-RunningPid
    if ($p) { Die "The loop is running (pid $p): it cleans up after each round." }
    if (-not (Test-Path -LiteralPath $CLEANUP)) { Die "No $CLEANUP." }
    $CLEANUP_ENABLED = '1'; $script:TotalCost = 0.0
    Set-RoundEnvironment
    Invoke-Cleanup ((Get-NextRound) - 1)
  }
  'prompt' { [Console]::Out.Write((Get-RenderedPrompt $(if ($CMD_ARGS.Count) { $CMD_ARGS[0] } else { 'N' }))) }
  'config' {
    foreach ($v in 'LOOP_DIR', 'WORKDIR', 'NAME', 'STATE_DIR', 'SCRATCH', 'CLAUDE_BIN', 'MODEL', 'EFFORT', 'SUBAGENT_MODEL',
      'PERMISSION_MODE', 'MAX_ROUNDS', 'MAX_TURNS', 'STALL_ROUNDS', 'MAX_FAILURES', 'MAX_COST', 'LIMIT_WAIT',
      'TRANSIENT_WAIT', 'CLASSIFIER_WAIT', 'CLEANUP_ENABLED', 'CLEANUP_MODEL', 'CLEANUP_TURNS', 'ADD_DIRS', 'EXPORT_ENV',
      'EXTRA_ARGS', 'GIT_NAME', 'GIT_EMAIL', 'NOTIFY', 'KEEP_AWAKE', 'FOLLOW_LINES', 'FOLLOW_WIDTH', 'WATCH_LINES',
      'WATCH_THINKING', 'COMMIT_ROUNDS', 'COMMIT_COUNT', 'EVERY', 'BASH_DEFAULT_TIMEOUT_MS', 'BASH_MAX_TIMEOUT_MS', 'PROJECT_DIR') {
      Out-Line ('{0,-24} {1}' -f $v, (Get-Variable -Name $v -ValueOnly))
    }
  }
  default { Show-Usage; exit 2 }
}
