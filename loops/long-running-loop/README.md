<p align="center">
  <img src="assets/hero.png" alt="An amber rocky planet, a violet ringed gas giant and a cyan ice planet represent coding, committing and checking work along a shared orbital path" width="960">
</p>

<h1 align="center">long-running-loop</h1>

<p align="center">
  Days-long work with Claude Code, one fresh round at a time.<br>
  Save progress in files, steer through an inbox and watch the work live.
</p>

---

Runs days-long work with Claude Code as a **loop of fresh, bounded rounds**. Each round is a
new `claude -p` session that reads the plan and the state from files, does one batch of
work, commits, records what it did and ends with a status line. `loop.sh` then starts the
next round.

Why: a single interactive session can't carry a refactor across a codebase or a port that
takes days. Its context grows to hundreds of thousands of tokens, replies get slow and
expensive, and a crash or a usage limit loses the thread. With rounds, every session starts
from about 15k tokens of files, the work survives crashes and limits, and you steer it by
writing to an inbox.

[`SKILL.md`](SKILL.md) is what Claude reads: how to set up a loop for a new topic, the round
protocol, the lessons it is built on and troubleshooting. This page is the quick tour.

## Requirements

bash 3.2+ (macOS's is fine), git, [jq](https://jqlang.github.io/jq/) and the `claude` CLI;
tmux for the `tmux` view. On macOS the loop sends notifications and keeps the machine awake
while it runs.

## Quick start

From the root of the git work tree the rounds will work in:

```sh
L=/path/to/skills/loops/long-running-loop/loop.sh   # or an alias

$L init           # creates .loop/ from the templates
# write .loop/PLAN.md (or ask Claude to, from your brief), the first Now items
# in .loop/PROGRESS.md, and adjust .loop/loop.conf; then commit .loop/
$L prompt 1       # read exactly what the first round will see
$L detach         # start in the background (survives the terminal)
$L tmux           # watch it
```

With the skill installed, asking Claude "set up a long-running loop for …" walks through
the brief, the plan and the settings.

## The loop directory

| File | Holds |
|---|---|
| `MEMORY.md` | The few fundamental concepts no round may ever forget; every round reads it first. Strictly reserved for fundamentals, written by you only. |
| `PLAN.md` | What to do: goal, context, rules, gates, tracks of checklist items with IDs, decisions, the final report. |
| `PROGRESS.md` | What happened and what's next: status, the ordered **Now** list, questions, blockers, one log line per round. |
| `PROMPT.md` | The generic prompt every round starts with; `loop.sh` fills its `{{PLACEHOLDERS}}`. |
| `INBOX.md` | Your new instructions. The next round folds them into PLAN or PROGRESS and empties it. |
| `CLEANUP.md` | Optional. The prompt of a short cleanup session the driver runs after each round (see below). |
| `loop.conf` | Settings: model, effort, git author, scratch directory, limits. The environment overrides them. |
| `state/` | Logs, lock, stop file, scratch. Git-ignored. |

The templates for all of them are in [`templates/`](templates).

## Commands

| Command | What it does |
|---|---|
| `init` | Create the loop directory from the templates (keeps existing files). |
| `run` / `detach` | Run the loop in this terminal, or in the background. |
| `stop [--now]` | Stop after the current round, or kill it now. |
| `status` | Running or not, the last rounds, cost. |
| `inbox [TEXT]` | Append a dated instruction to `INBOX.md` (no text: open `$EDITOR`). |
| `follow` / `watch` | Live views: the loop log with the round's last events, or the round's full transcript in colour. |
| `commits` | The work tree's commits grouped by round. |
| `tmux` | `watch`, `follow` and `commits` in three panes. |
| `cleanup` | Run the cleanup session now, for the last round (not while the loop runs). |
| `prompt [N]` / `config` | Print round N's prompt, or the effective settings. |

`-d DIR` picks the loop directory (default `./.loop`). The views only read: closing them
never touches the loop. `loop.sh --help` prints the full usage.

## Cleanup after each round

Rounds leave things behind: servers and test runners they started, temp files, stale build
outputs that fill the disk over days. When the loop directory has a `CLEANUP.md`, the
driver runs a short session after every round that ended with its status line, with
`CLEANUP.md` as its prompt, on a cheaper model (`CLEANUP_MODEL`, Sonnet by default). The
round itself spends nothing on cleanup, and a round that died keeps its leftovers for a
look.

`CLEANUP.md` lists what never to touch and what to clean; the template is a starting point
with the usual suspects. The session ends with one line, which the loop log shows:

```
[10-07 18:57] Round 45 ended: exit 0, 242 turns, $23.65 (total $23.65), 5 commit(s), ROUND: CONTINUE.
[10-07 18:57] Round 45 cleanup: CLEANUP: freed 26 GB, stopped 0 process(es).
```

Its transcript is in `state/logs/cleanup-NNN.json` and its cost counts toward the total.
`CLEANUP_ENABLED=0` turns it off; `CLEANUP_TURNS` caps its turns.

## How a run ends

Each round ends with `ROUND: CONTINUE`, `CHECKPOINT`, `BLOCKED <reason>` or `DONE`. The
driver starts the next round on `CONTINUE` and stops (with a notification) on the others.
It also stops on `MAX_ROUNDS`, `MAX_COST`, rounds without a commit or repeated failures, and
it waits out usage limits and API hiccups instead of counting them as failures.
