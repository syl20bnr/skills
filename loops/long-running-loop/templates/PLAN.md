# Plan: <title>

The work the loop carries out, round after round. This file holds only the plan: what to
build, the rules, the gates and the checklists. What was done, when and with which
evidence lives in PROGRESS.md. Rounds update this file when the plan itself changes (an
inbox instruction, a decision, a new checklist item) and tick items in the commit that
completes them.

## 1. Goal

<What exists when the work is done, in a few sentences. Who it is for and why.>

Out of scope: <what this work deliberately doesn't cover>.

## 2. Context

- Repository and branch: <path>, `<branch>` (never switch, never push).
- Read before working: <design docs, specs, prior reports>, by section when they are long.
- Reference to match, if any: <existing implementation, product, page>.
- Where things are: <crates/packages/directories that matter>.

## 3. Rules

Project rules every round follows, on top of the round prompt's.

- Commits: <author, message style, one focused change per commit>.
- Tests: <commands, the fast pass and the slow/timing pass, what "affected" means>.
- Delegation: <subagent model, effort, at most N at once, what they may touch>.
- Scratch and builds: <the fixed build directories under the scratch folder, job limits>.
- Never: <what must never happen: names that must not appear, files not to touch, gates not
  to relax>.

## 4. Gates

How "done" is measured. Each gate has a command or procedure and a budget. A round runs
the gates its batch affects; a checkpoint runs them all.

| Gate | How it is checked | Budget |
|---|---|---|
| G1 <name> | <command / procedure> | <threshold> |
| G2 <name> | <command / procedure> | <threshold> |

Checkpoint (ends a round with `ROUND: CHECKPOINT`): <which gates must pass together, with
fresh evidence>.

## 5. Work

Ordered tracks of checklist items. Each item has an ID, a clear outcome and, when useful,
its gate. Rounds work top-down within each track; PROGRESS's Now list says what is next.

### Track A: <name>

- [ ] A1 <outcome> (gate G1)
- [ ] A2 <outcome>

### Track B: <name>

- [ ] B1 <outcome>
- [ ] B2 <outcome>

## 6. Decisions

Settled answers that shape the work (from the user, or recorded interpretations). Don't
reopen them; add new ones with their date.

- <YYYY-MM-DD>: <decision>.

## 7. Final report

What the last round writes before `ROUND: DONE`: <file, contents: what passes, what fails,
measurements, remaining questions>.
