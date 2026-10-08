# Cleanup

What every round cleans up at its end, after its work is committed and before it updates
PROGRESS.md and prints its `ROUND:` line. One bullet per step: what to clean and how (a
command when there is one). Delete this file, or leave the list empty, when rounds have
nothing to clean. Rounds follow it as written and never remove work PROGRESS.md says to
preserve.

- (nothing yet; for example: stop the dev servers this round started, `pkill -f "vite"`;
  delete the build directories under the scratch folder that the next batch won't reuse;
  remove `*.orig` and `*.rej` files left by patches)
