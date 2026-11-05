# Mutation check

`make mutate` (`script/mutate.sh`) measures how many realistic bugs `make check` catches. It
plants one bug at a time in a worker copy of the checkout, builds it, and runs `make check`.
The checkout itself is never mutated.

## How it works

1. `script/mutation/generate.py` writes `Tests/Mutation/catalog.tsv`. It applies line-level
   operators to `DefiCore`, `DefiRuntime`, `DefiMacOS` and `DefiDaemon`, and labels each mutant
   with a bug type and an area. The operators are:
   - flipped comparisons, off by one, a dropped `&&` or `||` term, a negated guard;
   - forced boolean returns and assignments, dropped calls, write-twice;
   - delays or timeouts times ten, work moved off the input path, coalescing removed.

   `Tests/Mutation/curated.tsv` adds hand-written mutants for known bug shapes.
2. `script/mutation/sample.py` draws a stratified sample into `Tests/Mutation/sample.tsv`.
   - It keeps every curated mutant and tops each bug type up to 25 mutants.
   - It then fills by area weight (focus, discovery and layout first), with seed 1.
3. `script/mutation/run.py` runs the sample in parallel worker copies under
   `.build/mutation/workers/`, restoring the source after every mutant.
   - A mutant counts as killed only when `make check` exits 1 on a failing test or a crash, or
     when it times out.
   - `FAIL_FAST=1` stops the other lanes at the first failure.
   - Runs can be resumed with `RESUME=1`.
4. `script/mutation/report.py` writes `docs/testing/mutation-results.md`. It reports by type,
   by area, and per mutant.
   - Mutants that do not compile are excluded, and so are mutants whose line moved.
   - `Tests/Mutation/equivalent.tsv` lists equivalent mutants, each with its reason. They
     are excluded too.

## Result on 2026-11-05

- The catalog has 5 287 mutants, and the sample has 442.
- 382 sample mutants compile, and 52 of them are equivalent.
- 83 mutants are out of reach of an isolated loop. They are listed below.
- A full sample run takes about 2.9 hours with 4 workers.

| Bug type | Killed, all mutants | Killed, covered areas |
|---|---|---|
| Unexpected result | 114 of 138 (83%) | 114 of 121 (94%) |
| Multi-display leak | 21 of 24 (88%) | 21 of 22 (95%) |
| Lost input | 17 of 25 (68%) | 17 of 17 (100%) |
| Hang or busy loop | 16 of 20 (80%) | 16 of 18 (89%) |
| Oscillation | 15 of 22 (68%) | 15 of 18 (83%) |
| Stale write | 14 of 19 (74%) | 14 of 18 (78%) |
| Delay | 14 of 23 (61%) | 14 of 19 (74%) |
| Flicker | 12 of 24 (50%) | 12 of 17 (71%) |
| Glitch | 11 of 19 (58%) | 11 of 13 (85%) |
| Lag | 5 of 22 (23%) | 4 of 11 (36%) |
| Permission | 4 of 7 (57%) | 4 of 4 (100%) |
| Missing animation | 2 of 22 (9%) | 2 of 4 (50%) |
| **Total** | **245 of 365 (67%)** | **244 of 282 (87%)** |

The same sample caught 19% at the first run of this campaign. The score rose in four steps:

1. **More suites in the loop.** The guard-safe DefiMacOS and DefiDaemon suites joined
   `make check`, skipping only the individual tests that reach a real resource.
2. **Busy-app oracle.** The simulated desktop now counts each call to a busy app at the
   messaging timeout Defi set, and fails past 50 ms.
3. **Fake fixed by measurement.** The fake macOS was corrected from the real-desktop trace.
4. **One test per surviving mutant.** Each targeted test was written for one survivor and
   checked against that mutant. Rows with lane `targeted` in the results were killed by such a
   test, confirmed with a single-mutant run.

### Out of reach without real pixels or Accessibility

These mutants change behavior that only real AppKit panels, pixels, CADisplayLink, event taps,
TCC prompts, or the Accessibility of other apps can show. The isolation guard traps all of
these resources by design.

| Area | Mutants | Why |
|---|---|---|
| Overview panel (`OverviewController`, `DaemonOverview`) | 29 | zoom and fade animations run on a CADisplayLink in a real panel |
| Defi's own window writes (`OwnWindowAccessibilityWrite`) | 9 | the first line hops to the main thread for a real Accessibility write |
| Event tap and hotkey registration (`HotKeys`) | 9 | `CGEvent.tapCreate`, Carbon hotkeys and the private hotkey-mode read |
| Border panels (`WindowBorderObservation`, `WindowBorderSync`) | 7 | real border panels and their stacking |
| Permission alerts (`PermissionAlerts`) | 5 | `NSAlert` and System Settings |
| Real window discovery (`WindowSnapshotDiscovery`, `Snapshot`, `WindowAttributeRecording`) | 5 | the simulated desktop replaces the real discovery path with its own snapshot |
| Display configuration (`DisplayArrangementController`) | 2 | `CGConfigureDisplayOrigin` and live display reads |
| Others | 17 | enhanced-UI timeouts against real slow apps, animation state that only the overlay reads |

Most missing-animation mutants are in the Overview panel. Most lag mutants change the
timeouts of the real discovery path. Both types stay below target for that reason.

### Known limits

- **Masked suspects.** A mutant that reproduces a known suspect class is masked (see
  `known-suspects.md`).
- **Slightly order-dependent campaign.** A single seed replays identically, but 3 of
  560 seeds changed outcome between two full campaign runs, all within known suspect classes.
  State shared between scenarios in one process is the likely cause, so the green or red result
  is stable but the set of failing seeds is not.
- **Few permission mutants.** The catalog has only 9: permission checks are read directly in
  UI code, and the generator finds few lines to mutate.

### Findings outside the score

- The diagnostic `cancelled` counter of `AXFocusWriter` counts a cancelled pending request
  twice, once in `cancel()` and again when `drain()` skips it.
- The system-wide `kAXFocusedApplicationAttribute` write runs without a messaging timeout. The
  desktop fidelity trace shows macOS rejecting it at once (`kAXErrorInvalidUIElement`), so it
  does not wait for a busy app today.
