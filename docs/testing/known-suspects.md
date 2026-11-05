# Known suspects

These are the failure classes `make check` reports on `main`, triaged from a campaign of 100 000
simulated-desktop and 102 000 pure scenarios. Each is triaged here until a fix
lands or a desktop run confirms or rejects it.

The tests skip exactly these classes. The simulated-desktop suspects are listed in
`knownFocusSuspects` (`Tests/DefiSimulationTests/FocusInvariantHarness.swift`); the pure
runtime codes are listed in `RuntimeScenarioTests.knownCodes`. Remove an entry in the same
change that fixes it.

| Class | Lane | Status | Cause | Replay |
|---|---|---|---|---|
| `focus-index-out-of-range` | pure | confirmed: deterministic runtime logic, issue #222 | `joinFocusedWindow(.right)` from a stacked column leaves the source column's `focusedWindow` past its last row. Focusing that column again selects nothing (`focus-column-missed`). | `open ×3, nativeFocus(2), join left, join right, focus column left` |
| `native-converges ["axCallTakesUpToItsTimeout"]` | simulated desktop | suspect: not yet reproduced on the desktop | Typing while a column focus is in flight cancels it. `commandFocusCancellationFallback` then returns `previousSelectedWindowID`, although the requested window is already macOS's key window. | `DEFI_SCENARIO_SEED=9`: `[press, press, type]` |
| `native-converges ["axCallTakesUpToItsTimeout", "busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]` | simulated desktop | variant of the row above | Same rollback after a busy app's activation landed late. | seed 34 |
| `native-converges ["busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]` | simulated desktop | variant | Same, without the slow call. | seed 38 |
| `native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate"]` | simulated desktop | variant | Same, after a late focus notification. | seed 63 |
| `native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate", "writerRunsDuringTapCallout"]` | simulated desktop | suspect | A Defi focus write still in flight lands after the user's Command-Tab or click and takes focus back from the window the user chose. Found once in 100 000 scenarios. | `DEFI_SCENARIO_SEED=2433` |
| `native-converges ["focusNotificationArrivesLate"]` | simulated desktop | suspect | The user's Command-Tab is reported late. Column presses made meanwhile start from Defi's old selection, queue a focus that never commits, and Defi and macOS stay on different windows once calm. Found only by the PCT scheduler. | `DEFI_SCENARIO_SEED=230`, PCT lane |

| `typing-target-kept` (3 classes: plain, busy app, writer during tap) | simulated desktop | suspect | A superseded focus write still in flight finishes after newer typing and moves macOS away from the window the user typed into. Found by the typing oracle added after the mutation check. | `DEFI_SCENARIO_SEED=370`: `[press, writerStep, press (writer during tap), type]` |

## Classification on 2026-11-05

The focus suspects were replayed on the GitHub macos-26 runner by
`SuspectReplayTests`, with the real daemon and `MacOSPlatform`, two Defi fixture apps, the
target app's main thread busy for 300 ms before each press, and a keystroke right after. A
round is inconclusive when macOS shows no managed window in front or the keystroke target was
not read.

| Classes | Verdict | Evidence |
|---|---|---|
| `focus-index-out-of-range` | confirmed | deterministic in the pure runtime, issue #222 |
| `native-converges` typing rollback (4 rows above) | not reproduced | 0 divergent rounds of 29 conclusive |
| `typing-target-kept` (3 classes) | not reproduced | 0 divergent rounds of 29 conclusive |
| `native-converges ["focusNotificationArrivesLate"]` and the writer during a Command-Tab | not replayed | a fixture app cannot activate itself, and a real Command-Tab needs HID input on the runner |
| `focus-visible` with `accessibilityRevoked` | harness defect, fixed | see below |
| `busy-app-call-unbounded` at 6 000 ms | harness defect, fixed | see below |

False-alarm rate: of the 4 simulated-desktop classes checked against the real system, 2 were
harness defects and 2 did not reproduce in 29 conclusive rounds each, so none is confirmed
(4 of 4 not seen on the real desktop). The replay stands in for Accessibility notifications with
a desktop sync every 100 ms and cannot force the exact interleaving the simulation found, so
"not reproduced" keeps those classes as suspects rather than closing them.

## Harness defects found and fixed

| Class | Cause | Fix |
|---|---|---|
| `focus-visible` with `accessibilityRevoked` | The simulated snapshot reported no window away from its target, so frames refused while Accessibility was revoked were never rewritten. The real snapshot reports such mismatches. | The simulated snapshot reports target mismatches with the production rule. The class no longer appears in 36 000 scenarios. |
| `busy-app-call-unbounded` at 6 000 ms | The fake kept messaging timeouts per equal element, but the simulated snapshot recreates element references; one thread's reset erased another's timeout. | Timeouts are kept per element reference, as Defi's `AXMessagingTimeoutAccess` does. |

The simulated-desktop rows still use the simulated desktop snapshot, which stands in for
`SnapshotEngine`. A desktop or CI run should confirm them before the fix.
