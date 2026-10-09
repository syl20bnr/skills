---
name: long-running-loop
description: Run a long, multi-session piece of work with Claude Code as a loop of fresh, bounded rounds driven by loop.sh (MEMORY.md, PLAN.md, PROGRESS.md, PROMPT.md, INBOX.md, CLEANUP.md, detached runner, live and tmux views). Use when setting up such a loop for a new topic, writing its plan, starting, monitoring, steering or troubleshooting it.
---

# Long-running loop

Some work takes days: a refactor across a codebase, porting an application, a
performance programme with gates. A single interactive session can't carry it: its
context grows to hundreds of thousands of tokens, each answer gets slower and more
expensive, older details blur, and a crash or a usage limit loses the thread.

This skill runs the work as a **loop of rounds**. Each round is a fresh, non-interactive
`claude -p` session. It reads the plan and the state from files, does one bounded batch of
work, commits, records what it did and ends with a status line. The driver, `loop.sh`,
then starts the next round. Context stays small (each round starts from about 15k tokens of
files), the work survives crashes and limits, and you steer it by writing to an inbox.

## The files

A loop is a directory (default `.loop/` at the root of the work tree) holding:

| File | Holds | Who writes it |
|---|---|---|
| `MEMORY.md` | The few fundamental concepts no round may ever forget (where code belongs, what must never happen, how the work is judged). Every round reads it first and follows it over everything else. Strictly reserved for fundamentals: no tasks, steps, findings or paths; a handful of short entries at most. | You only (directly, or an inbox item that says "remember"); rounds never edit it on their own. |
| `PLAN.md` | The plan only: goal, context, rules, gates, tracks of checklist items with IDs, decisions, the final report's contents. | You (or Claude, from your brief) at setup; rounds when the plan changes (an inbox instruction, a decision) and to tick items. |
| `PROGRESS.md` | The state: Status, the ordered **Now** list, uncommitted work to preserve, open questions, blockers, one Log line per round. | Rounds, every round. |
| `PROMPT.md` | The prompt every round starts with. Generic: it tells the round how to read, work and end. `{{PLACEHOLDERS}}` are filled in by `loop.sh`. | Rarely changed. Project rules go in PLAN.md, not here. |
| `INBOX.md` | Your new instructions, as dated bullets. The next round folds them into PLAN or PROGRESS and empties it. | You, any time, even mid-round (`loop.sh inbox "..."`). |
| `CLEANUP.md` | Optional. The prompt of a short session (`CLEANUP_MODEL`, Sonnet by default) the driver runs after every round that ended with its status line: it stops processes the round left, empties TMPDIR, prunes stale build outputs, and ends with `CLEANUP: freed <N> GB, stopped <M> process(es)`, which the loop log shows as `Round N cleanup: …`. Absent: no cleanup. | You, at setup or any time. |
| `loop.conf` | Settings (shell assignments); the environment overrides them. | You. |
| `state/` | Logs (`loop.log`, `round-NNN.json`), lock, stop file, default scratch. Git-ignored. | `loop.sh`. |

Keep the separation strict: MEMORY is what must never be forgotten, PLAN is what to do, PROGRESS is what happened and what's
next. A plan that accumulates logs becomes unreadable for the next round, and a progress
file that restates the plan drifts from it.

## Setting up a loop for a new topic

When the user asks for a loop on some work:

1. **Gather the brief** (their goal, constraints, references, how success is measured).
   Ask what you can't infer: the gates and the definition of done matter most.
2. **Create the loop:** `loop.sh -d <work tree>/.loop init` copies the templates.
3. **Write PLAN.md** from the brief, replacing every `<placeholder>`:
   - **Goal** and out-of-scope, in a few sentences.
   - **Context:** the repository, branch, documents to read (with sections), references to
     match.
   - **Rules:** commit style and author, test commands (fast pass, slow pass), delegation
     (subagent model, at most N at once), scratch and build directories, the "nevers".
   - **Gates:** each with a command or procedure and a budget, and the **checkpoint** (which
     gates must pass together; it makes a round end with `ROUND: CHECKPOINT`).
   - **Work:** tracks of checklist items with IDs (`A1`, `B3`), each a clear outcome,
     ordered. Two tracks work well: one for the hard core (the coordinator does it), one
     for parallel breadth work (delegated to subagents).
   - **Decisions:** what is settled, dated.
   - **Final report:** what the last round writes before `ROUND: DONE`.
   Put in **MEMORY.md** only what is fundamental to every round (a principle the user
   insists on, a line never to cross); most loops start with it empty. Don't abuse it: a
   memory that grows into a second plan stops being read as fundamental.
4. **Write PROGRESS.md's first Now items** (the first batch), and leave the rest empty.
   **Write CLEANUP.md** from the template: what to clean (processes, temp files, stale
   build outputs) and what never to touch. Delete it if rounds leave nothing behind.
5. **Adjust `loop.conf`:** model, effort, `GIT_NAME`/`GIT_EMAIL`, `SCRATCH` on a disk with
   room for builds, `ADD_DIRS` for other directories the rounds need, `EXPORT_ENV` (for
   example `CARGO_BUILD_JOBS=4` so parallel builds don't overheat the machine),
   `MAX_ROUNDS`, `MAX_COST`.
6. **Commit the loop directory** on the branch the rounds will work on.
7. **Start and watch:** `loop.sh -d … detach`, then `loop.sh -d … tmux`.

Before starting, read the rendered prompt once (`loop.sh prompt 1`): it is exactly what the
first round will see.

## Running and watching

```sh
L=/path/to/skills/loops/long-running-loop/loop.sh   # or an alias
$L -d .loop detach            # start in the background (survives the terminal)
$L -d .loop tmux              # watch: transcript | loop log / commits by round
$L -d .loop status            # running or not, last rounds, cost
$L -d .loop inbox "From now on, ..."   # steer the next round
$L -d .loop stop              # stop after the current round (clean)
$L -d .loop stop --now        # stop now, killing the round (its files stay on disk)
```

`-d` defaults to `./.loop`, so from the work tree's root `loop.sh detach` is enough.

| Command | What it does |
|---|---|
| `init` | Creates the loop directory from the templates (keeps existing files). |
| `run` | Runs the loop in this terminal. Ctrl-C kills the current round too. |
| `detach` | Runs the loop in the background with `nohup`; refuses to start a second one. |
| `stop [--now]` | Stops after the current round; `--now` kills the round. |
| `status` | Running or not, stop requested, the last 15 log lines in colour. |
| `follow` | Live view: the loop log in colour and, under the running round, its last events (`FOLLOW_LINES=0` for the log only). |
| `watch` | Streams the loop log's new lines (bold magenta) and the running round's transcript: thinking (grey), messages (green), tool calls (yellow, input in cyan, `(bg)` when backgrounded), results with their duration and first lines (dim, errors in red), subagents marked `[sub]`. Switches to each new round's session by itself, skipping other Claude sessions in the same folder. `WATCH_LINES` sets the history shown at start, `WATCH_THINKING=0` hides thinking. |
| `commits [-r N] [-n N] [--once]` | The work tree's commits grouped by round (from the loop log), oldest first, one per line: `<sha> 2h ago (<files>f/+<added>/-<removed>) <message>`. |
| `tmux` | A tmux session: `watch` on the left, `follow` (log only) top right, `commits -r 3` bottom right. Reattaches if it exists. Only displays: it never starts or stops the loop. |
| `inbox [TEXT]` | Appends a dated bullet to INBOX.md, or opens it in `$EDITOR`. |
| `cleanup` | Runs CLEANUP.md now, for the last round (refuses while the loop runs). |
| `prompt [N]` | Prints the prompt round N gets. |
| `config` | Prints every setting with its effective value. |

The views only read: Ctrl-C in a view, or closing the tmux session, never touches the loop.

## Steering

- **Write to the inbox, not to PLAN or PROGRESS,** while a round runs: rounds rewrite those
  files at their end and would overwrite or trip over your edit. The next round reads the
  inbox first, folds each item where it belongs (a rule or decision into PLAN, an action
  into PROGRESS's Now at the stated priority) and empties it.
- **Make something unforgettable** with an inbox item that says to remember it in MEMORY.md,
  or edit MEMORY.md between rounds. Reserve it for fundamental concepts only.
- **Give priorities explicitly** in the inbox ("top priority, before anything else", "next
  Track B batch").
- **Answer questions** the rounds leave under "Questions" in PROGRESS through the inbox; a
  round never waits for an answer and continues with independent work.
- **Change settings** in `loop.conf`, then restart (`stop`, wait for "Stopped on request",
  `detach`). A running loop keeps the code and settings it started with.

## The round protocol

Every round ends with exactly one status line, the last line of its output:

| Status | Meaning | The driver |
|---|---|---|
| `ROUND: CONTINUE` | More work remains. | Starts the next round. |
| `ROUND: CHECKPOINT` | A checkpoint from PLAN is reached, evidence recorded. | Stops and notifies: review, then restart. |
| `ROUND: BLOCKED <reason>` | Nothing useful can proceed without the user. | Stops and notifies. |
| `ROUND: DONE` | The plan is complete, the final report written. | Stops and notifies. |

After a round that printed its status line, the driver runs the CLEANUP.md session and logs
its `CLEANUP:` line; a round without one keeps its leftovers for a look.

The driver also stops on: the stop file, `MAX_ROUNDS` rounds in this run, `STALL_ROUNDS`
rounds in a row without a commit, `MAX_FAILURES` failed sessions in a row, `MAX_COST`.

It waits and retries, without counting a round, when the session reports a usage limit
(until the reset time when the CLI gives one, else `LIMIT_WAIT`), when auto mode's
server-side safety check is unavailable (`CLASSIFIER_WAIT`), and on an overloaded or 5xx API
error before any work (`TRANSIENT_WAIT`). A round interrupted for any reason leaves its
files on disk; the next round finds them through `git status` and finishes or shelves them.

## Lessons this loop is built on

These came from running it for days on a large codebase; the templates and the script
already encode them.

- **One interactive session for days doesn't work.** At 600k tokens of context each reply
  is slow and expensive. Fresh rounds of one batch each cost a fraction and lose nothing,
  because the state is in files.
- **A non-interactive round ends when its turn ends.** A round that starts the test suite in
  the background and says "I'll review once it finishes" ends right there and loses the
  run. The prompt forbids ending the turn while anything runs.
- **Rounds must end themselves.** Without "one batch, then end", a round keeps going and its
  context grows again. A stray "don't stop after a round" in PROGRESS undoes the loop.
- **Bookkeeping is a budget.** A previous agent spent most of 60 rounds on diagnostics,
  provenance and dense paragraphs while the gates stayed red. "Every round ends with a
  committed fix or a reverted experiment", and a short PROGRESS with links to evidence
  files, keep the work moving.
- **Builds can melt the machine.** Each subagent with its own cold build directory meant
  240 GB of build output, an overheated Mac (`kernel_task` throttling) and random test
  processes killed at startup. Reuse a fixed set of build directories, cap parallel jobs
  (`EXPORT_ENV="CARGO_BUILD_JOBS=4"`), keep scratch out of Spotlight and backups.
- **Detach the loop from the terminal.** A frozen or closed terminal, or Ctrl-C, kills the
  round with the loop. `detach` runs it under `nohup`; the views are separate commands.
- **Gates must cover what users touch.** The representative flow scrolled with a mouse
  wheel; a trackpad gesture took another path and lagged. A slow page outside the flow went
  unnoticed until a sweep of every page was added to the gates. Put every interaction kind
  and every page in the gates, and add a gate whenever the user reports something the
  gates missed.
- **Verify what the user sees.** Numeric checks passed while hover jittered by a pixel and
  text went soft; a frame-by-frame look at a screen recording found it. Ask for recordings
  and captures, and compare them, for visual work.
- **Server-side hiccups happen.** Overloaded APIs and an unavailable auto-mode classifier
  ended rounds; the driver now waits and retries instead of counting failures.
- **macOS ships bash 3.2.** `case` patterns inside `$( … )` don't parse there; keep such
  logic in functions. Test scripts with `/bin/bash` on macOS.

## Troubleshooting

- **"`follow` doesn't start the loop":** it doesn't; only `run` and `detach` do.
- **Nothing happens after a checkpoint:** by design. Review PROGRESS, then `detach` again.
- **"The loop is already running" but nothing moves:** `status` shows the pid; `stop --now`
  if it is stuck. A stale lock (dead pid) is ignored automatically.
- **A round ended with "no status line":** read its `state/logs/round-NNN.json` (`.result`,
  `.errors`, `.subtype`). The next round recovers its uncommitted work.
- **Views show no events:** transcripts live in `~/.claude/projects/<work tree path with
  every non-alphanumeric character as "-">/`; `config` prints the path (`PROJECT_DIR`).
- **Rounds are too expensive:** lower `EFFORT`, set `MAX_COST`, make batches smaller in
  PLAN's rules, check that rounds don't read whole large files.
