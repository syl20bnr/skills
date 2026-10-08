#!/usr/bin/env bash
# long-running-loop: runs a long task as a loop of fresh Claude Code sessions.
#
# Each round is a new, non-interactive `claude -p` session with an empty context.
# It reads the loop's files, does one bounded batch of work, commits, records what
# it did and ends with a status line; then the next round starts. No session ever
# carries a huge context, and the plan survives crashes, limits and restarts.
#
# A loop lives in a directory (default ./.loop) holding five files:
#   PLAN.md      the work to do: goal, rules, gates, checklists (evolves slowly)
#   PROGRESS.md  the state: status, next actions, open questions, one log line per round
#   PROMPT.md    the prompt every round starts with ({{PLACEHOLDERS}} are filled in)
#   INBOX.md     your new instructions; the next round folds them into PLAN/PROGRESS
#   CLEANUP.md   what a short session cleans up after each round (optional)
# plus loop.conf (settings) and state/ (logs, lock, scratch; git-ignored).
#
# Usage: loop.sh [-d LOOP_DIR] COMMAND [ARGS]
#
#   init              create LOOP_DIR with the five files, loop.conf and state/
#   run               run the loop in this terminal (Ctrl-C kills the current round)
#   detach            run the loop in the background, detached from the terminal
#   stop [--now]      stop after the current round (--now: kill the round too)
#   status            running or not, the last rounds, cost
#   follow            live view: the loop log in colour and the round's last events
#   watch             stream the loop log and the running round's transcript in colour
#   commits [-r N] [-n N] [--once]
#                     the work tree's commits, grouped by round, refreshing
#   tmux              a tmux session with watch, follow and commits in three panes
#   inbox [TEXT]      append a dated instruction to INBOX.md (no TEXT: open $EDITOR)
#   cleanup           run CLEANUP.md now, for the last round (not while the loop runs)
#   prompt [N]        print the prompt round N would get
#   config            print the effective settings
#
# Settings: LOOP_DIR/loop.conf (shell assignments), overridden by the environment.
# `loop.sh config` lists them all with their values; `init` writes a commented
# loop.conf. Requires bash 3.2+ (macOS's), git, jq and the claude CLI; tmux for `tmux`.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
SKILL_DIR="$(dirname "$SELF")"
TEMPLATES="$SKILL_DIR/templates"

usage() { sed -n '2,/^set -uo/p' "$SELF" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- arguments

LOOP_DIR="${LOOP_DIR:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--dir) LOOP_DIR="${2:?-d needs a directory}"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) break ;;
  esac
done
CMD="${1:-}"
[ $# -gt 0 ] && shift
[ -n "$CMD" ] || { usage; exit 2; }
[ -n "$LOOP_DIR" ] || LOOP_DIR="$PWD/.loop"
case "$LOOP_DIR" in /*) ;; *) LOOP_DIR="$PWD/$LOOP_DIR" ;; esac

# ---------------------------------------------------------------- colours

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  RST=$'\033[0m' BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GREEN=$'\033[32m'
  YELLOW=$'\033[33m' BLUE=$'\033[34m' MAGENTA=$'\033[35m' CYAN=$'\033[36m'
else
  RST='' BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN=''
fi
die() { printf '%s%s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ---------------------------------------------------------------- init

if [ "$CMD" = init ]; then
  [ -d "$TEMPLATES" ] || die "Templates not found in $TEMPLATES."
  mkdir -p "$LOOP_DIR/state"
  for f in PLAN.md PROGRESS.md PROMPT.md INBOX.md CLEANUP.md loop.conf; do
    if [ -e "$LOOP_DIR/$f" ]; then
      echo "kept     $LOOP_DIR/$f"
    else
      cp "$TEMPLATES/$f" "$LOOP_DIR/$f" && echo "created  $LOOP_DIR/$f"
    fi
  done
  [ -e "$LOOP_DIR/.gitignore" ] || printf 'state/\n' > "$LOOP_DIR/.gitignore"
  cat <<EOF

Next:
  1. Write PLAN.md (the goal, rules, gates and checklists) and the first "Now" items
     of PROGRESS.md. Ask Claude to draft them from your brief if you like.
  2. List in CLEANUP.md what every round must clean up at its end (or delete it).
  3. Adjust loop.conf (model, effort, limits, extra directories, environment).
  4. Commit the loop directory, then: $(basename "$SELF") -d $LOOP_DIR detach
     and watch it with: $(basename "$SELF") -d $LOOP_DIR tmux
EOF
  exit 0
fi

[ -d "$LOOP_DIR" ] || die "No loop in $LOOP_DIR (create one with: $(basename "$SELF") -d $LOOP_DIR init)."

# ---------------------------------------------------------------- settings

# loop.conf first, then the environment wins: re-apply the exported variables.
ENV_SNAPSHOT="$(export -p)"
# shellcheck disable=SC1091
[ -f "$LOOP_DIR/loop.conf" ] && . "$LOOP_DIR/loop.conf"
eval "$ENV_SNAPSHOT" 2>/dev/null

WORKDIR="${WORKDIR:-$(git -C "$LOOP_DIR" rev-parse --show-toplevel 2>/dev/null || dirname "$LOOP_DIR")}"
NAME="${NAME:-$(basename "$WORKDIR")}"
STATE_DIR="${STATE_DIR:-$LOOP_DIR/state}"
SCRATCH="${SCRATCH:-$STATE_DIR/scratch}"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
MODEL="${MODEL:-claude-opus-5-5}"
EFFORT="${EFFORT:-high}"
SUBAGENT_MODEL="${SUBAGENT_MODEL:-sonnet}"
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
MAX_ROUNDS="${MAX_ROUNDS:-30}"
MAX_TURNS="${MAX_TURNS:-500}"
STALL_ROUNDS="${STALL_ROUNDS:-2}"
MAX_FAILURES="${MAX_FAILURES:-3}"
MAX_COST="${MAX_COST:-}"
LIMIT_WAIT="${LIMIT_WAIT:-1800}"
TRANSIENT_WAIT="${TRANSIENT_WAIT:-300}"
CLASSIFIER_WAIT="${CLASSIFIER_WAIT:-600}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-1}"
CLEANUP_MODEL="${CLEANUP_MODEL:-claude-sonnet-5-5}"
CLEANUP_TURNS="${CLEANUP_TURNS:-40}"
ADD_DIRS="${ADD_DIRS:-}"
EXPORT_ENV="${EXPORT_ENV:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
NOTIFY="${NOTIFY:-1}"
KEEP_AWAKE="${KEEP_AWAKE:-1}"
TMUX_SESSION="${TMUX_SESSION:-loop-$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9_-' '-')}"
FOLLOW_LINES="${FOLLOW_LINES:-10}"
FOLLOW_WIDTH="${FOLLOW_WIDTH:-2}"
WATCH_LINES="${WATCH_LINES:-40}"
WATCH_THINKING="${WATCH_THINKING:-1}"
COMMIT_ROUNDS="${COMMIT_ROUNDS:-3}"
COMMIT_COUNT="${COMMIT_COUNT:-40}"
EVERY="${EVERY:-2}"
BASH_DEFAULT_TIMEOUT_MS="${BASH_DEFAULT_TIMEOUT_MS:-3600000}"
BASH_MAX_TIMEOUT_MS="${BASH_MAX_TIMEOUT_MS:-7200000}"

PLAN="$LOOP_DIR/PLAN.md"
PROGRESS="$LOOP_DIR/PROGRESS.md"
PROMPT="$LOOP_DIR/PROMPT.md"
INBOX="$LOOP_DIR/INBOX.md"
CLEANUP="$LOOP_DIR/CLEANUP.md"
LOGS="$STATE_DIR/logs"
SUMMARY="$LOGS/loop.log"
LOCK="$STATE_DIR/loop.lock"
STOP_FILE="$STATE_DIR/loop.stop"
mkdir -p "$LOGS" "$SCRATCH/tmp"
touch "$SUMMARY"

# Claude Code keeps a project's transcripts under its path with every
# non-alphanumeric character replaced by a dash.
PROJECT_DIR="$HOME/.claude/projects/$(printf '%s' "$WORKDIR" | sed 's/[^A-Za-z0-9]/-/g')"

# ---------------------------------------------------------------- helpers

running_pid() {
  local pid
  [ -f "$LOCK" ] || return 1
  pid="$(cat "$LOCK" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && { echo "$pid"; return 0; }
  return 1
}

g() { git -C "$WORKDIR" --no-optional-locks "$@"; }

notify() {
  [ "$NOTIFY" = 1 ] && command -v osascript >/dev/null 2>&1 &&
    osascript -e "display notification \"$1\" with title \"Loop: $NAME\"" >/dev/null 2>&1
  return 0
}

# Colours one loop log line by what it says.
colorize() {
  awk -v rst="$RST" -v bold="$BOLD" -v dim="$DIM" -v red="$RED" -v green="$GREEN" \
      -v yellow="$YELLOW" -v magenta="$MAGENTA" -v cyan="$CYAN" '
    {
      c = rst
      if ($0 ~ /starting at/) c = bold cyan
      else if ($0 ~ / cleanup: /) c = ($0 ~ /no CLEANUP line|exit [1-9]/) ? yellow : bold
      else if ($0 ~ /ROUND: CONTINUE/ && $0 !~ / 0 commit/) c = green
      else if ($0 ~ /ROUND: (CHECKPOINT|DONE)|Checkpoint|Done:/) c = bold green
      else if ($0 ~ /ROUND: BLOCKED|Blocked|in a row|without a commit|failed/) c = bold red
      else if ($0 ~ /no status line|exit [1-9]| 0 commit/) c = yellow
      else if ($0 ~ /[Uu]sage limit|[Tt]ransient|retrying|safety check/) c = yellow
      else if ($0 ~ /Stopped|interrupted|Loop started|Reached/) c = bold magenta
      line = $0
      if (match(line, /^\[[^]]*\]/)) {
        ts = substr(line, 1, RLENGTH); line = substr(line, RLENGTH + 1)
        printf "%s%s%s%s%s%s\n", dim, ts, rst, c, line, rst
      } else printf "%s%s%s\n", c, line, rst
    }'
}

say() {
  local line
  line="$(printf '[%s] %s' "$(date '+%m-%d %H:%M')" "$1")"
  printf '%s\n' "$line" >> "$SUMMARY"
  printf '%s\n' "$line" | colorize
  notify "$1"
}

# Cuts lines to FOLLOW_WIDTH times the given width (0 keeps whole lines).
clip() {
  if [ "$FOLLOW_WIDTH" -gt 0 ] 2>/dev/null; then cut -c1-$(($1 * FOLLOW_WIDTH)); else cat; fi
}

# The prompt of round $1 (or the file $2, e.g. CLEANUP.md), placeholders filled in.
render_prompt() {
  local p branch
  p="$(cat "${2:-$PROMPT}")"
  branch="$(g rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  p="${p//\{\{LOOP_DIR\}\}/$LOOP_DIR}"
  p="${p//\{\{WORKDIR\}\}/$WORKDIR}"
  p="${p//\{\{STATE_DIR\}\}/$STATE_DIR}"
  p="${p//\{\{SCRATCH\}\}/$SCRATCH}"
  p="${p//\{\{PLAN\}\}/$PLAN}"
  p="${p//\{\{PROGRESS\}\}/$PROGRESS}"
  p="${p//\{\{INBOX\}\}/$INBOX}"
  p="${p//\{\{CLEANUP\}\}/$CLEANUP}"
  p="${p//\{\{ROUND\}\}/$1}"
  p="${p//\{\{MAX_ROUNDS\}\}/$MAX_ROUNDS}"
  p="${p//\{\{BRANCH\}\}/$branch}"
  p="${p//\{\{NAME\}\}/$NAME}"
  printf '%s\n' "$p"
}

# The transcripts of the newest round: the main one and its subagents'.
# Rounds are named "$NAME round N", which their transcript's first line
# records; other sessions in the same folder are skipped (the newest session
# is the fallback).
transcript_files() {
  local main sid f
  main="$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-[^/]*\.jsonl$' | head -20 |
    while IFS= read -r f; do
      head -c 4000 "$f" | head -1 | grep -qF "\"customTitle\":\"$NAME round " && { echo "$f"; break; }
    done)"
  [ -n "$main" ] || main="$(ls -t "$PROJECT_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-[^/]*\.jsonl$' | head -1)"
  [ -n "$main" ] || return 0
  sid="$(basename "$main" .jsonl)"
  echo "$main"
  for f in "${main%.jsonl}"/subagents/*.jsonl; do [ -f "$f" ] && echo "$f"; done
  for f in $(find "$PROJECT_DIR" -maxdepth 1 -name 'agent-*.jsonl' -mmin -240 2>/dev/null); do
    head -c 4000 "$f" | head -1 | grep -q "\"sessionId\":\"$sid\"" && echo "$f"
  done
}

# Transcript events, one per line, sorted: key, time, kind, text.
# The key (timestamp|uuid|index) orders and deduplicates them.
events() {
  local think=false
  [ "${1:-0}" = 1 ] && think=true
  transcript_files | while IFS= read -r f; do tail -n "${EVENT_TAIL:-400}" "$f"; done |
  jq -rR --argjson think "$think" '
    def one: tostring | gsub("[\n\t\r]"; " ");
    def hms: if type == "string" and length > 0
      then (sub("\\.[0-9]+"; "") | fromdateiso8601 | localtime | strftime("%H:%M:%S"))
      else "--:--:--" end;
    fromjson? | select(.type == "assistant" or .type == "user") | . as $l
    | ($l.timestamp // "") as $t | ($t | hms) as $h
    | (if $l.isSidechain then "sub " else "" end) as $s
    | ($l.message.content // []) | (if type == "array" then . else [] end)
    | to_entries[] | .key as $i | .value | select(type == "object")
    | "\($t)|\($l.uuid // "")|\($i)" as $k
    | if $l.type == "assistant" then
        (if .type == "text" then "\($k)\t\($h)\t\($s)say\t\(.text | one)"
         elif .type == "tool_use" then "\($k)\t\($h)\t\($s)tool\t\(.name) \((.input.command // .input.file_path // .input.pattern // .input.description // .input.prompt // "") | one)"
         elif .type == "thinking" and $think then "\($k)\t\($h)\t\($s)think\t\(.thinking | one)"
         else empty end)
      else
        (if .type == "tool_result" then "\($k)\t\($h)\t\($s)\(if .is_error then "error" else "done" end)\t\((.content | if type == "array" then map(.text? // "") | join(" ") else tostring end) | one)"
         else empty end)
      end' 2>/dev/null | sort
}

# Prints events (stdin) as coloured lines, cut to the given width.
print_events() {
  local width="$1" key hms kind text c
  while IFS=$'\t' read -r key hms kind text; do
    case "${kind:-}" in
      *say) c="$GREEN" ;;
      *tool) c="$YELLOW" ;;
      *error) c="$RED" ;;
      *think) c="$DIM" ;;
      *) c="$DIM" ;;
    esac
    printf '%s%s%s %s%-9s%s %s\n' "$DIM" "${hms:-}" "$RST" "$c" "${kind:-}" "$RST" \
      "$(printf '%s' "${text:-}" | clip "$width")"
  done
}

# ---------------------------------------------------------------- run

# After a round that ended with its status line, a short session follows
# CLEANUP.md to remove what the round left behind (processes, temp files, stale
# build outputs) and reports one `CLEANUP:` line, which goes to the loop log. A
# round that died or was interrupted keeps its leftovers, for a look.
cleanup_round() {
  local n="$1" log out code cost d
  [ "$CLEANUP_ENABLED" = 1 ] && [ -f "$CLEANUP" ] || return 0
  log="$(printf '%s/cleanup-%03d.json' "$LOGS" "$n")"
  local cargs=(--model "$CLEANUP_MODEL" --permission-mode "$PERMISSION_MODE"
               --output-format json --max-turns "$CLEANUP_TURNS" --add-dir "$LOOP_DIR")
  case "$SCRATCH" in "$WORKDIR"/*) ;; *) cargs+=(--add-dir "$SCRATCH") ;; esac
  for d in $ADD_DIRS; do cargs+=(--add-dir "$d"); done
  (
    cd "$WORKDIR" || exit 1
    exec "$CLAUDE_BIN" -p "$(render_prompt "$n" "$CLEANUP")" "${cargs[@]}" --name "$NAME cleanup $n"
  ) > "$log" 2> "${log%.json}.stderr" < /dev/null &
  child=$!
  wait "$child"; code=$?; child=""
  cost="$(jq -r '.total_cost_usd // 0' "$log" 2>/dev/null)"
  total_cost="$(awk -v a="${total_cost:-0}" -v b="${cost:-0}" 'BEGIN { printf "%.2f", a + b }')"
  out="$(jq -r '.result // empty' "$log" 2>/dev/null | grep -E '^CLEANUP: ' | tail -1)"
  say "Round $n cleanup: ${out:-no CLEANUP line (exit $code), see $log}."
}

run_loop() {
  local pid
  command -v "$CLAUDE_BIN" >/dev/null || die "The claude CLI ($CLAUDE_BIN) is not on PATH."
  command -v jq >/dev/null || die "jq is required (brew install jq)."
  for f in "$PLAN" "$PROGRESS" "$PROMPT"; do [ -f "$f" ] || die "Missing $f (run init)."; done
  [ -f "$INBOX" ] || printf '# Inbox\n' > "$INBOX"
  if pid="$(running_pid)"; then die "The loop is already running (pid $pid)."; fi
  echo $$ > "$LOCK"
  rm -f "$STOP_FILE"

  child=""
  cleanup() { [ -n "$child" ] && kill "$child" 2>/dev/null; rm -f "$LOCK"; }
  trap 'say "Loop interrupted."; cleanup; exit 130' INT TERM HUP
  trap cleanup EXIT

  export TMPDIR="$SCRATCH/tmp"
  export BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS
  export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS="${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS:-0}"
  export CLAUDE_CODE_SUBAGENT_MODEL="$SUBAGENT_MODEL"
  if [ -n "$GIT_NAME" ]; then export GIT_AUTHOR_NAME="$GIT_NAME" GIT_COMMITTER_NAME="$GIT_NAME"; fi
  if [ -n "$GIT_EMAIL" ]; then export GIT_AUTHOR_EMAIL="$GIT_EMAIL" GIT_COMMITTER_EMAIL="$GIT_EMAIL"; fi
  local kv
  for kv in $EXPORT_ENV; do export "$kv"; done
  if [ "$KEEP_AWAKE" = 1 ] && command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i -w $$ >/dev/null 2>&1 &
  fi

  local args=(--model "$MODEL" --effort "$EFFORT" --permission-mode "$PERMISSION_MODE"
              --output-format json --add-dir "$LOOP_DIR")
  [ "$MAX_TURNS" -gt 0 ] 2>/dev/null && args+=(--max-turns "$MAX_TURNS")
  case "$SCRATCH" in "$WORKDIR"/*) ;; *) args+=(--add-dir "$SCRATCH") ;; esac
  local d
  for d in $ADD_DIRS; do args+=(--add-dir "$d"); done
  # shellcheck disable=SC2206
  local extra=($EXTRA_ARGS)

  local total_cost=0 stalls=0 failures=0 rounds=0 n log before code result status
  local is_error cost turns commits text errors reset now wait_s slept
  say "Loop started in $WORKDIR ($MODEL, effort $EFFORT, at most $MAX_ROUNDS rounds)."
  while [ "$rounds" -lt "$MAX_ROUNDS" ]; do
    if [ -f "$STOP_FILE" ]; then say "Stopped on request."; rm -f "$STOP_FILE"; exit 0; fi
    n=1; while [ -e "$(printf '%s/round-%03d.json' "$LOGS" "$n")" ]; do n=$((n + 1)); done
    log="$(printf '%s/round-%03d.json' "$LOGS" "$n")"
    before="$(g rev-parse HEAD 2>/dev/null || echo none)"
    say "Round $n starting at $(g log -1 --format=%h 2>/dev/null || echo none)."
    (
      cd "$WORKDIR" || exit 1
      exec "$CLAUDE_BIN" -p "$(render_prompt "$n")" "${args[@]}" \
        --name "$NAME round $n" ${extra[@]+"${extra[@]}"}
    ) > "$log" 2> "${log%.json}.stderr" &
    child=$!
    wait "$child"; code=$?; child=""

    result="$(jq -r '.result // empty' "$log" 2>/dev/null)"
    is_error="$(jq -r '.is_error // false' "$log" 2>/dev/null)"
    cost="$(jq -r '.total_cost_usd // 0' "$log" 2>/dev/null)"
    turns="$(jq -r '.num_turns // 0' "$log" 2>/dev/null)"
    errors="$(jq -r '.errors[]? // empty' "$log" 2>/dev/null)"
    total_cost="$(awk -v a="$total_cost" -v b="${cost:-0}" 'BEGIN { printf "%.2f", a + b }')"
    commits="$(g rev-list --count "$before"..HEAD 2>/dev/null || echo 0)"
    status="$(printf '%s\n' "$result" | grep -E '^ROUND: ' | tail -1)"
    say "Round $n ended: exit $code, $turns turns, \$$(printf '%.2f' "${cost:-0}") (total \$$total_cost), $commits commit(s), ${status:-no status line}."
    [ -n "$status" ] && cleanup_round "$n"

    # Waits that don't count as a round: usage limit, lost safety classifier
    # (auto mode), transient API errors before any work.
    text="$result $errors $(tail -c 2000 "${log%.json}.stderr" 2>/dev/null)"
    wait_s=0
    if [ -z "$status" ] && printf '%s' "$text" | grep -qiE 'usage limit|rate limit|hit your limit|limit reached|resets? (at|in)'; then
      reset="$(printf '%s' "$text" | grep -oE '\|[0-9]{9,}' | tr -d '|' | head -1)"
      now="$(date +%s)"
      if [ -n "$reset" ] && [ "$reset" -gt "$now" ]; then wait_s=$((reset - now + 120)); else wait_s="$LIMIT_WAIT"; fi
      say "Usage limit: waiting $((wait_s / 60)) min, then retrying."
    elif printf '%s' "$errors" | grep -qiE 'auto mode is unavailable|no safety verdict'; then
      wait_s="$CLASSIFIER_WAIT"
      say "Auto mode's safety check is unavailable (server side); retrying in $((wait_s / 60)) min."
    elif [ -z "$status" ] && [ "$commits" -eq 0 ] && [ "${turns:-0}" -le 2 ] &&
         printf '%s' "$text" | grep -qiE 'API Error: 5[0-9][0-9]|overloaded'; then
      wait_s="$TRANSIENT_WAIT"
      say "Transient API error; retrying in $((wait_s / 60)) min."
    fi
    if [ "$wait_s" -gt 0 ]; then
      slept=0
      while [ "$slept" -lt "$wait_s" ]; do
        [ -f "$STOP_FILE" ] && { say "Stopped on request."; rm -f "$STOP_FILE"; exit 0; }
        sleep 30; slept=$((slept + 30))
      done
      continue
    fi

    rounds=$((rounds + 1))
    if [ "$code" -ne 0 ] || [ "$is_error" = true ] || [ -z "$result" ]; then
      failures=$((failures + 1))
      [ "$failures" -ge "$MAX_FAILURES" ] && { say "$MAX_FAILURES failed rounds in a row; see $LOGS."; exit 4; }
    else
      failures=0
    fi
    if [ "$commits" -eq 0 ]; then stalls=$((stalls + 1)); else stalls=0; fi
    [ "$stalls" -ge "$STALL_ROUNDS" ] && { say "$STALL_ROUNDS rounds without a commit; stopping for a look."; exit 5; }
    if [ -n "$MAX_COST" ] && awk -v t="$total_cost" -v m="$MAX_COST" 'BEGIN { exit !(t >= m) }'; then
      say "Reached MAX_COST (\$$total_cost)."; exit 6
    fi
    case "$status" in
      "ROUND: CHECKPOINT"*) say "Checkpoint reached: review PROGRESS.md, then rerun to continue."; exit 0 ;;
      "ROUND: BLOCKED"*) say "Blocked: ${status#ROUND: BLOCKED }"; exit 3 ;;
      "ROUND: DONE"*) say "Done: the plan is complete."; exit 0 ;;
    esac
  done
  say "Reached MAX_ROUNDS ($MAX_ROUNDS); rerun to continue."
}

# ---------------------------------------------------------------- views

status_view() {
  local pid
  if pid="$(running_pid)"; then echo "${GREEN}Running${RST} (pid $pid) in $WORKDIR"
  else echo "${YELLOW}Not running.${RST} ($WORKDIR)"; fi
  [ -f "$STOP_FILE" ] && echo "${MAGENTA}Stop requested after the current round.${RST}"
  tail -n "${1:-15}" "$SUMMARY" | colorize
}

# One frame of the live view. A function, not inline in $(...): macOS's bash
# 3.2 can't parse `case` patterns inside a command substitution.
follow_frame() {
  local cols="$1" running="$2" last logn lines="$FOLLOW_LINES"
  last="$(tail -n 1 "$SUMMARY" 2>/dev/null)"
  logn="${FOLLOW_LOG:-$(( $(tput lines 2>/dev/null || echo 30) - 4 - lines ))}"
  [ "$logn" -lt 3 ] && logn=3
  printf '%s%s: %s%s  %s(%s, Ctrl-C quits the view only)%s\n\n' \
    "$BOLD" "$NAME" "$running" "$RST" "$DIM" "$(date '+%H:%M:%S')" "$RST"
  tail -n "$logn" "$SUMMARY" | clip "$cols" | colorize
  [ "$lines" -gt 0 ] || return 0
  case "$last" in *"starting at"*) ;; *) return 0 ;; esac
  events 0 | tail -n "$lines" | print_events $((cols - 20)) | sed "s/^/  ${DIM}│${RST} /"
}

follow_view() {
  local cols out running pid
  trap 'printf "\033[?25h\n"; exit 0' INT TERM
  printf '\033[?25l\033[2J'
  while :; do
    cols="$(tput cols 2>/dev/null || echo 120)"
    if pid="$(running_pid)"; then running="running (pid $pid)"; else running="not running"; fi
    [ -f "$STOP_FILE" ] && running="$running, stop requested"
    out="$(follow_frame "$cols" "$running")"
    printf '\033[H%s\033[J' "$(printf '%s\n' "$out" | sed $'s/$/\033[K/')"
    sleep "$EVERY"
  done
}

# The watch view's jq program: one coloured line per transcript event, each
# shown once (deduplicated by uuid). Thinking in dark grey, messages in green,
# tool calls in yellow with their input in cyan, results dimmed with their
# duration and first lines, errors in red; subagents' lines are marked [sub].
WATCH_FILTER='
def c(code; s): if $color then "\u001b[" + code + "m" + s + "\u001b[0m" else s end;
def secs: (.timestamp // null) as $t
  | if ($t | type) == "string" then ($t | sub("\\.[0-9]+"; "") | fromdateiso8601) else null end;
def hms($s): if $s then ($s | localtime | strftime("%H:%M:%S")) else "--:--:--" end;
def txt: if type == "string" then .
  elif type == "array" then map(select(type == "object" and .type == "text") | .text) | join("\n")
  else tostring end;
def one: tostring | gsub("\n"; " ⏎ ");
foreach (inputs | fromjson? | select(.type == "assistant" or .type == "user")) as $l
  ({started: {}, out: [], seen: {}};
   .out = []
   | if ($l.uuid != null and .seen[$l.uuid]) then . else
   (if $l.uuid != null then .seen[$l.uuid] = true else . end)
   | ($l | secs) as $now
   | (hms($now) + (if $l.isSidechain then " [sub]" else "" end)) as $ts
   | if $l.type == "assistant" then
       reduce ($l.message.content[]? | select(type == "object")) as $b (.;
         if $b.type == "thinking" then
           (if $think then .out += [c("2;90"; $ts + " [think] " + ($b.thinking | one | .[0:300]))] else . end)
         elif $b.type == "text" then
           .out += [c("32"; $ts + " [say]   " + $b.text)]
         elif $b.type == "tool_use" then
           .started[$b.id] = $now
           | .out += [c("1;33"; $ts + " [tool]  " + $b.name
                + (if ($b.input.run_in_background // false) then " (bg)" else "" end))
              + "  " + c("36"; (($b.input.command // $b.input.file_path // $b.input.pattern
                   // $b.input.description // $b.input.prompt // "") | one | .[0:220]))]
         else . end)
     else
       reduce ($l.message.content[]? | select(type == "object" and .type == "tool_result")) as $r (.;
         (.started[$r.tool_use_id] // null) as $t0
         | (if $t0 and $now then " " + ((($now - $t0) | floor) | tostring) + "s" else "" end) as $dur
         | (($r.content // "") | txt | split("\n") | map(select(length > 0))) as $lines
         | .out += [c(if ($r.is_error // false) then "31" else "2;37" end;
              $ts + " [done]" + $dur + "  " + (($lines[0:2] | join(" ⏎ ")) | .[0:220])
              + (if ($lines | length) > 2 then "  … +" + ((($lines | length) - 2) | tostring) + " lines" else "" end))]
         | del(.started[$r.tool_use_id]))
     end
   end;
   .out[])'

# Stops a process and all its descendants (backgrounded pipelines don't get
# Ctrl-C, and their tails would outlive the view). Parents go first, so no
# subshell lives to report its children as terminated.
kill_tree() {
  local children child
  children="$(pgrep -P "$1")"
  kill "$1" 2>/dev/null
  for child in $children; do kill_tree "$child"; done
}

# Streams the loop in real time: the loop log's new lines in bold magenta and
# the running round's transcript (messages, tool calls, results, subagents),
# switching to each new round's session by itself.
watch_view() {
  local color=false think=false current="" files="" latest now kept added
  local logpid="" pid=""
  command -v jq >/dev/null || die "jq is required (brew install jq)."
  [ -n "$RST" ] && color=true
  [ "$WATCH_THINKING" = 1 ] && think=true
  [ -d "$PROJECT_DIR" ] || echo "No transcripts yet in $PROJECT_DIR (waiting for the first round)."

  # start_follower <old files> <new files> <history lines>: old files from
  # their end (or their last <history lines>), new files from their first
  # line, all through one jq so each line shows once.
  start_follower() {
    (
      IFS=$'\n'
      {
        [ -n "$1" ] && tail -q -n "$3" -F $1 2>/dev/null &
        [ -n "$2" ] && tail -q -n +1 -F $2 2>/dev/null &
        wait
      } | jq -nrR --unbuffered --argjson color "$color" --argjson think "$think" "$WATCH_FILTER"
    ) &
    pid=$!
  }
  # Waiting on the stopped jobs keeps bash from reporting them as terminated.
  stop_follower() { [ -n "$pid" ] && { kill_tree "$pid"; wait "$pid" 2>/dev/null; }; pid=""; }
  stop_all() {
    stop_follower
    [ -n "$logpid" ] && { kill_tree "$logpid"; wait "$logpid" 2>/dev/null; }
    logpid=""
  }
  trap 'stop_all; exit 0' INT TERM
  trap stop_all EXIT

  status_view 6; echo
  (
    tail -n 0 -F "$SUMMARY" 2>/dev/null | while IFS= read -r line; do
      printf '%s%s%s%s\n' "$BOLD" "$MAGENTA" "$line" "$RST"
    done
  ) &
  logpid=$!

  while :; do
    now="$(transcript_files)"
    latest="$(printf '%s\n' "$now" | head -1)"
    if [ -n "$latest" ]; then
      if [ "$latest" != "$current" ]; then
        stop_follower
        current="$latest" files="$now"
        printf '%s%s=== following %s ===%s\n' "$BOLD" "$MAGENTA" "$(basename "$current")" "$RST"
        start_follower "$files" "" "$WATCH_LINES"
      elif [ "$now" != "$files" ]; then
        # A subagent started: keep the lines already shown, add its file from
        # its first line.
        kept="$(comm -12 <(printf '%s\n' "$files" | sort) <(printf '%s\n' "$now" | sort))"
        added="$(comm -13 <(printf '%s\n' "$files" | sort) <(printf '%s\n' "$now" | sort))"
        stop_follower
        files="$now"
        start_follower "$kept" "$added" 0
      fi
    fi
    sleep "$EVERY"
  done
}

# One line per commit of a range: hash, age, time, size, subject coloured by type.
commit_lines() {
  local count="$1"; shift
  g log --no-merges -n "$count" --date=format:'%a %H:%M' \
    --format=$'\x1e%h\x1f%ar\x1f%ad\x1f%s' --shortstat "$@" 2>/dev/null |
  awk -v RS=$'\x1e' -v FS=$'\x1f' -v rst="$RST" -v dim="$DIM" -v red="$RED" \
      -v green="$GREEN" -v yellow="$YELLOW" -v blue="$BLUE" -v magenta="$MAGENTA" -v cyan="$CYAN" '
    NF < 4 { next }
    {
      split($4, rest, "\n"); subject = rest[1]
      files = 0; ins = 0; del = 0
      if (match($0, /[0-9]+ files? changed/)) files = substr($0, RSTART, RLENGTH) + 0
      if (match($0, /[0-9]+ insertions?/)) ins = substr($0, RSTART, RLENGTH) + 0
      if (match($0, /[0-9]+ deletions?/)) del = substr($0, RSTART, RLENGTH) + 0
      type = subject; sub(/[(:!].*/, "", type)
      c = rst
      if (type == "feat") c = green
      else if (type == "fix") c = red
      else if (type == "perf") c = cyan
      else if (type == "test") c = yellow
      else if (type == "refactor") c = magenta
      else if (type == "docs" || type == "chore" || type == "style") c = dim
      age = $2; sub(/ ago$/, "", age)
      printf "  %s%s%s %s%-14s%s %s%s%s %s%3d f %+6d %-6s%s %s%s%s\n", yellow, $1, rst, blue, age, rst, \
        dim, $3, rst, dim, files, ins, "-" del, rst, c, subject, rst
    }'
}

commits_frame() {
  local rounds="$1" count="$2" starts total shown upper n start out label oldest
  printf '%s%s  %s  HEAD %s  %s uncommitted%s\n' "$BOLD" "$(date '+%H:%M:%S')" \
    "$(g rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(g log -1 --format='%h %ar' 2>/dev/null)" \
    "$(g status --porcelain 2>/dev/null | wc -l | tr -d ' ')" "$RST"
  printf '%sloop: %s%s\n\n' "$MAGENTA" "$(tail -1 "$SUMMARY" | cut -c1-110)" "$RST"
  starts="$(sed -n 's/.*Round \([0-9]*\) starting at \([0-9a-f]*\)\..*/\1 \2/p' "$SUMMARY" |
            awk '{ last[$1] = $2 } END { for (n in last) print n, last[n] }' | sort -n)"
  if [ -z "$starts" ]; then commit_lines "$count" HEAD; return; fi
  total="$(echo "$starts" | wc -l | tr -d ' ')"
  upper=HEAD shown=0
  while read -r n start; do
    [ "$rounds" -gt 0 ] && [ "$shown" -ge "$rounds" ] && break
    shown=$((shown + 1))
    out="$(commit_lines "$count" "$start..$upper")"
    label="round $n"; [ "$upper" = HEAD ] && label="round $n (latest)"
    printf '%s── %s, from %s ──%s\n' "$MAGENTA" "$label" "$start" "$RST"
    if [ -n "$out" ]; then printf '%s\n' "$out"; else printf '  %s(no commit)%s\n' "$DIM" "$RST"; fi
    upper="$start"
  done <<EOF
$(echo "$starts" | sort -rn)
EOF
  [ "$rounds" -gt 0 ] && [ "$rounds" -lt "$total" ] && return
  oldest="$(echo "$starts" | head -1 | cut -d' ' -f2)"
  printf '%s── before the loop ──%s\n' "$MAGENTA" "$RST"
  commit_lines 12 "$oldest"
}

commits_view() {
  local rounds=0 count="$COMMIT_COUNT" once=0 out
  while [ $# -gt 0 ]; do
    case "$1" in
      -r) rounds="${2:?-r needs a number}"; shift ;;
      -n) count="${2:?-n needs a number}"; shift ;;
      --once) once=1 ;;
      *) die "commits: unknown option $1" ;;
    esac
    shift
  done
  if [ "$once" = 1 ]; then commits_frame "$rounds" "$count"; return; fi
  trap 'printf "\033[?25h"; exit 0' INT TERM
  printf '\033[?25l'
  while :; do
    out="$(commits_frame "$rounds" "$count")"
    printf '\033[H\033[2J%s\n' "$out"
    sleep $((EVERY * 5))
  done
}

tmux_view() {
  local main side below me
  command -v tmux >/dev/null || die "tmux is not installed (brew install tmux)."
  me="$(printf '%q' "$SELF") -d $(printf '%q' "$LOOP_DIR")"
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    main="$(tmux new-session -d -s "$TMUX_SESSION" -c "$WORKDIR" \
      -x "$(tput cols 2>/dev/null || echo 200)" -y "$(tput lines 2>/dev/null || echo 50)" -P -F '#{pane_id}')"
    side="$(tmux split-window -h -t "$main" -c "$WORKDIR" -l 45% -P -F '#{pane_id}')"
    below="$(tmux split-window -v -t "$side" -c "$WORKDIR" -l 50% -P -F '#{pane_id}')"
    # Typed into each pane's shell: Ctrl-C in a pane leaves a prompt to rerun it.
    tmux send-keys -t "$main" "$me watch" C-m
    tmux send-keys -t "$side" "env FOLLOW_LINES=0 $me follow" C-m
    tmux send-keys -t "$below" "$me commits -r $COMMIT_ROUNDS" C-m
    tmux select-pane -t "$main"
  fi
  if [ -n "${TMUX:-}" ]; then tmux switch-client -t "$TMUX_SESSION"; else tmux attach -t "$TMUX_SESSION"; fi
}

# ---------------------------------------------------------------- commands

case "$CMD" in
  run|start) run_loop ;;
  detach)
    if pid="$(running_pid)"; then echo "The loop is already running (pid $pid)."; exit 0; fi
    nohup "$SELF" -d "$LOOP_DIR" run >> "$LOGS/detached.out" 2>&1 &
    sleep 2
    if pid="$(running_pid)"; then
      echo "${GREEN}Loop started${RST} in the background (pid $pid). Watch: follow, watch or tmux. Stop: stop."
    else
      die "The loop didn't start; see $LOGS/detached.out."
    fi ;;
  stop)
    if [ "${1:-}" = --now ]; then
      if pid="$(running_pid)"; then kill -TERM "$pid" && echo "Stopped the loop and its round (pid $pid)."
      else echo "Not running."; fi
    else
      touch "$STOP_FILE"
      echo "${MAGENTA}The loop stops after the current round${RST} (rm $STOP_FILE to cancel)."
    fi ;;
  status) status_view 15 ;;
  follow) follow_view ;;
  watch) watch_view ;;
  commits) commits_view "$@" ;;
  tmux) tmux_view ;;
  inbox)
    [ -f "$INBOX" ] || printf '# Inbox\n' > "$INBOX"
    if [ $# -gt 0 ]; then
      printf '\n- %s: %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$INBOX"
      echo "Added to $INBOX; the next round takes it in."
    else
      "${EDITOR:-vi}" "$INBOX"
    fi ;;
  cleanup)
    if pid="$(running_pid)"; then die "The loop is running (pid $pid): it cleans up after each round."; fi
    command -v jq >/dev/null || die "jq is required (brew install jq)."
    [ -f "$CLEANUP" ] || die "No $CLEANUP."
    n=1; while [ -e "$(printf '%s/round-%03d.json' "$LOGS" "$n")" ]; do n=$((n + 1)); done
    child=""; CLEANUP_ENABLED=1; export TMPDIR="$SCRATCH/tmp"
    cleanup_round "$((n - 1))" ;;
  prompt) render_prompt "${1:-N}" ;;
  config)
    for v in LOOP_DIR WORKDIR NAME STATE_DIR SCRATCH CLAUDE_BIN MODEL EFFORT SUBAGENT_MODEL \
             PERMISSION_MODE MAX_ROUNDS MAX_TURNS STALL_ROUNDS MAX_FAILURES MAX_COST LIMIT_WAIT \
             TRANSIENT_WAIT CLASSIFIER_WAIT CLEANUP_ENABLED CLEANUP_MODEL CLEANUP_TURNS ADD_DIRS EXPORT_ENV EXTRA_ARGS GIT_NAME GIT_EMAIL NOTIFY \
             KEEP_AWAKE TMUX_SESSION FOLLOW_LINES FOLLOW_WIDTH WATCH_LINES WATCH_THINKING \
             COMMIT_ROUNDS COMMIT_COUNT EVERY BASH_DEFAULT_TIMEOUT_MS BASH_MAX_TIMEOUT_MS PROJECT_DIR; do
      printf '%-24s %s\n' "$v" "${!v}"
    done ;;
  *) usage; exit 2 ;;
esac
