# Retro-validation of the isolated loop

Each fixed bug of the corpus is replayed without a hand-written scenario. On the parent of the
merge commit, the loop must report a failure class. On the merge commit, that class must be gone.
The simulated macOS may only use catalog behaviors whose source predates the fix. A failure class
present on both sides belongs to another bug.

Two lanes ran:

- **Pure lane:** `RuntimeScenarioTests`, `RuntimeLayoutChecks` and `RuntimeState.validate()`, run
  against `DefiRuntime` and `DefiCore` of the revision.
- **Simulated desktop lane:** `FocusInvariantHarnessTests`, run against the revision's real
  `Daemon`, `MacOSPlatform`, `InputMonitor`, `AXFocusWriter` and `AXFrameCoordinator`. The
  simulated macOS stands behind them.

Ports onto older revisions are API compatibility only. They remove commands that did not exist
yet, route the clock through `DefiClock` and add the injection seams. They never change generator
weights, seeds or invariants.

## Result: 2 of 18 found, below the 50% checkpoint

| PR | Family | Result | Evidence or reason |
|---|---|---|---|
| #216 | focus | **found** | Parent `4d41912c`: `latest-intent-wins` at seed 3 in 1.1 s, shrunk to `[press(right), press(right, writer runs during tap)]`. The class shows `axCallTakesUpToItsTimeout` and `writerRunsDuringTapCallout`, plus two convergence classes with the same behavior. Merge `b8b56b11` keeps only the four triaged suspects. The busy-app half (#210) appears on older revisions and disappears after #216. |
| #213 | focus | not found | Parent and merge report the same 8 classes. A Dock press needs mouse input and the WindowServer inventory, which the simulated snapshot does not model. |
| #166 | focus | not found | Parent and merge report the same 5 classes. The simulated desktop does not open or close windows yet. |
| #124 | focus | not run | Its parent's `Daemon` cannot take an instance lock, topology store or state publisher. Running it would touch the user's real session files and notifications. |
| #118, #105, #71, #59, #34 | focus | not run | These revisions predate `AXFocusOperations` (#123), the seam the simulated focus writer needs. |
| #164 | layout | **found** | Parent `4ecc4a48`: `tiled-gap`, a column inside the right outer gap, shrunk to `open, maximize, open` in 0.1 s. The merge `2dd3f819` is clean. The rule comes from the `gaps` row of CONFIGURATION.md, which predates the fix. |
| #193 | layout | not found | The pure lane has no mouse drag. A "drop lands under the pointer" oracle written after reading #193 would be hindsight. |
| #111 | layout | not found | The per-application placement lived in the daemon's `PlacementStore`, outside the pure lane. |
| #108 | layout | not found | That era predates `parkedFrame`, so the pure lane has no parking check there. |
| #114 | layout | not found | The fix needs native size acceptance reported by apps. |
| #110, #84, #79 | layout | not found | Nothing remains once the two persistent older classes are skipped (`DEFI_SCENARIO_SKIP=tiled-gap,tiled-minimum-width`). These fixes depend on native frame feedback or on display glue. |
| #51 | layout | not run | The pure kit does not compile on that revision. |

Not attempted yet: the discovery family (#116, #115, #107, #104, #86, #72, #40, #106, #49) and
#215, #117, #70, #218. They need the real `SnapshotEngine` on a simulated Accessibility and
WindowServer layer, which does not exist yet.

## Suspects found on `main` (not yet confirmed on the desktop)

- **Stale row index after a join.** Calling `joinWindow(.right)` from a stacked column leaves the
  source column's focused row out of range, in `joinFocusedWindow`. Focusing that column again
  then selects nothing. Pure lane, invariant `focus-index-out-of-range`, triaged in
  `RuntimeScenarioTests.knownCodes`.
- **Rollback to a window macOS never focused.** Typing while a column focus is in flight rolls
  the selection back to the previous window, although the requested window is already macOS's
  key window. `commandFocusCancellationFallback` returns `previousSelectedWindowID` without
  checking native focus. Simulated desktop lane, seed 9 shrinks to
  `[press, press, type]`. The four `native-converges` suspect classes in `knownFocusSuspects` are
  this rollback and its busy-app variants.

## What would raise the score

1. **Simulate the raw macOS layer.** Accessibility attributes and observers, the WindowServer
   window list, workspace activation and screens would let the real `SnapshotEngine` run. This
   reaches the discovery family, #213 and #71.
2. **Extend the simulated desktop.** Window lifecycle (#166, #111), mouse presses and drags
   (#213, #193, #218) and native size feedback (#114, #84, #110).
3. **Earlier eras need a different seam.** Revisions before #123 and before daemon injection would
   need their focus writer and daemon refactored, so their fixes stay out of reach.
