# Mutation check

`make mutate` (`script/mutate.sh`) plants one realistic bug at a time and runs `make check`.
It reports whether the loop kills the bug, and which lane and tests caught it.

The mutants cover layout, focus and frame code. They also cover areas the loop is not expected
to reach yet, so the score stays honest.

## Result on 2026-11-04: 29 of 53 killed (55%)

An earlier run reported 31 kills. Two of them came from a load-sensitive IPC test failing by
chance, which now runs alone before the parallel lanes.

| Area | Killed | Survivors |
|---|---|---|
| Layout, lifecycle, routing | 20 of 25 | join focus, focus after a column closes, reorder past the trailing workspace, workspace position off by one, command rollback onto another monitor |
| Focus | 7 of 13 | daemon fallback after failure, inactive app not activated, writer ignores newer input, redundant focus write, recovery target, hotkeys while the keyboard is captured |
| Frames | 2 of 7 | size writes on position-only navigation, stale-write detection, superseded size writes, write ordering, parking repair |
| Not simulated yet | 2 of 8 | classification (2), snapshot focus (3), mouse drop slot, overview drop, borders |

The lane column shows who caught each kill. Most kills come from the unit tests that already
existed. Only three bugs were caught by the new scenarios alone: empty inactive workspaces
that are never removed, unchanged frames rewritten, and write diffing against the stale native
frame.

## What the survivors say

- **Typing hides focus bugs.** The step oracle stops checking after any human input. That is
  why "the writer ignores newer input" survives. The fix is a typing-aware oracle: after typing,
  macOS's key window must stay the one the user typed into.
- **The fake accepts every write at once.** Extra, stale or reordered writes therefore never
  change the final frames. Adding the catalog's delayed and superseded writes would make them
  visible.
- **Missing command postconditions.** There are none for join, close, reorder or position
  targets.
- **No real snapshot or classification path.** The real `SnapshotEngine` does not run on the
  simulated macOS yet, and there are only 8 classification fixtures.
