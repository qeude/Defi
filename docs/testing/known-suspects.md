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
| `focus-index-out-of-range` | pure | suspect: logic confirmed by a pure test, not yet seen on the desktop | `joinFocusedWindow(.right)` from a stacked column leaves the source column's `focusedWindow` past its last row. Focusing that column again selects nothing (`focus-column-missed`). | `open ×3, nativeFocus(2), join left, join right, focus column left` |
| `native-converges ["axCallTakesUpToItsTimeout"]` | simulated desktop | suspect: not yet reproduced on the desktop | Typing while a column focus is in flight cancels it. `commandFocusCancellationFallback` then returns `previousSelectedWindowID`, although the requested window is already macOS's key window. | `DEFI_SCENARIO_SEED=9`: `[press, press, type]` |
| `native-converges ["axCallTakesUpToItsTimeout", "busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]` | simulated desktop | variant of the row above | Same rollback after a busy app's activation landed late. | seed 34 |
| `native-converges ["busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]` | simulated desktop | variant | Same, without the slow call. | seed 38 |
| `native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate"]` | simulated desktop | variant | Same, after a late focus notification. | seed 63 |
| `native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate", "writerRunsDuringTapCallout"]` | simulated desktop | suspect | A Defi focus write still in flight lands after the user's Command-Tab or click and takes focus back from the window the user chose. Found once in 100 000 scenarios. | `DEFI_SCENARIO_SEED=2433` |
| `native-converges ["focusNotificationArrivesLate"]` | simulated desktop | suspect | The user's Command-Tab is reported late. Column presses made meanwhile start from Defi's old selection, queue a focus that never commits, and Defi and macOS stay on different windows once calm. Found only by the PCT scheduler. | `DEFI_SCENARIO_SEED=230`, PCT lane |

The simulated-desktop rows still use the simulated desktop snapshot, which stands in for
`SnapshotEngine`. A desktop or CI run should confirm them before the fix.
