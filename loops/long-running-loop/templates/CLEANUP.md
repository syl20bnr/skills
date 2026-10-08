# Cleanup after round {{ROUND}}

You run right after round {{ROUND}} of the loop on `{{NAME}}` ended with its `ROUND:` line. The
round is over: nothing it started should still be running. Your job is to remove what it
left behind (processes, temporary files, stale build outputs), so the machine stays
responsive and the disk doesn't fill across rounds. You change no code and no tracked file,
and make no commits. Be quick: a handful of commands, then report.

The work tree is `{{WORKDIR}}`, the scratch folder `{{SCRATCH}}`. Only touch what "Clean"
lists; when in doubt, leave it.

## Never touch

- The work tree's tracked and untracked files, any git directory, the loop's files
  (`{{LOOP_DIR}}`) and its logs.
- Anything `{{PROGRESS}}` lists under "Uncommitted work" or links to as evidence.
- <your own builds, tools and processes the rounds must leave alone>

## Clean

1. Processes the round left running (`ps -Ao pid,ppid,etime,command`): servers, apps, test
   runners and builds it started and orphaned. Stop them (`kill`, then `kill -9` after 5 s)
   and list each one with its command line in your report.
2. `{{SCRATCH}}/tmp` (the rounds' TMPDIR): delete everything in it.
3. <stale build outputs: for example older test executables and incremental sessions in the
   build directories under the scratch folder>
4. Extra git worktrees the round added and no longer needs: `git worktree remove --force`,
   never `rm` alone.

## Report

Print the processes you stopped and the size of what you cleaned before and after
(`du -sh`), then exactly one last line:
`CLEANUP: freed <N> GB, stopped <M> process(es)` (or `CLEANUP: skipped <reason>`).
