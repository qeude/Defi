# Native link focus

Initial analysis recorded on 2026-09-05. Implementation and verification results follow below.

## Defi activation constraints

Before the implementation below, Defi accepted an application activation only when its latest focus intent is still the latest input and is at most two seconds old. Runtime admission also required a current keyboard or deferred mouse intent. See [UserInputTracking.swift](../../Sources/DefiMacOS/UserInputTracking.swift) and [FocusSelection.swift](../../Sources/DefiRuntime/FocusSelection.swift). A legitimate delayed activation can therefore fail these conditions. This is a source-based explanation of a possible miss, not a trace-confirmed diagnosis of every reported failure.

The recommended next change is to admit confirmed external native activation independently of a recent-click token, resolve the exact window while the activation remains current, and retain Defi's existing command ordering and own-focus suppression. Do not select an arbitrary window by PID. Preserve explicit empty-workspace selection against unchanged or stale native observations. Recheck generation and current frontmost application after asynchronous reads, and cancel pending resolution when superseded.

Following confirmed native activation can also follow a programmatic activation accepted by macOS. These signals cannot prove a human clicked a link. Avoid promising both universal link-opening success and rejection of every unwanted programmatic activation from the same observations.

Before implementation is considered reliable, correlate Defi traces with real external opens: existing target on an inactive workspace, multiple windows of the same app, slow AX response, keyboard link activation, another user command arriving during resolution, delayed own-focus echoes, and an active empty workspace. This research changed documentation only and did not run third-party code or desktop benchmarks.

## Implementation and verification

Implemented on 2026-09-05 using public NSWorkspace activation and Accessibility focus reads. External app activation no longer requires a recent click. Resolution expires after two seconds, checks the current frontmost process, and cannot consume a newer activation. New focus input invalidates pending resolution; ordinary typing does not. Desktop admission also checks the latest Defi command timestamp. Existing internal-focus suppression retires matching activation echoes so they cannot reappear after suppression expires.

While resolving an activation, AX failures no longer reuse a previous window. The existing bounded snapshot scheduling retries the read. A matching activation is rechecked after the AX read and again on the main thread before admission. Accepted native focus reveals the workspace without requesting native focus again, and can preempt an older command animation.

Validation: `swift build`, `swift test` with 746 passing tests, and `./script/build_and_run.sh --verify` passed. `./script/test_desktop.sh` passed 18 tests with Accessibility available; one test was skipped because it required a second on-screen managed window. Computer Use opened a temporary Finder internet-location file in Helium across virtual workspaces, with two traced admissions reporting `activation=true accepted=true mouseIntent=false keyboardIntent=false`. The empty trailing workspace remained selected after waiting, and a matching internal activation reported `reason=internal-focus-echo`. Test tabs and the temporary Finder window were closed. The initial dev workspace and Codex selection were restored, the installed code-signing requirement was unchanged, and exactly one daemon remained.

These desktop checks used one monitor and do not establish universal success across applications or every event ordering. The two-second limit bounds AX resolution, not the age of the link click. Same-application AX-only notifications retain the existing native-focus handling.

## PR review corrections

Both Greptile findings on PR #59 were reproduced with failing regression tests. A consumed click could acquire a new target from an unrelated later focus event. An activation echo matching an internal focus request could also borrow newer keyboard input or a click on another window to bypass suppression.

The correction removes consumed-click resurrection and the two-second release-correlation heuristic. Release correlation is scoped to the pending release snapshot again. Application activation no longer rebinds mouse intent; its separate, current activation token still admits legitimate external focus after the source click has been consumed.

A matching internal activation remains suppressed while its write is outstanding or has failed, unless newer pointer input explicitly identifies that same window. A click elsewhere cannot establish its external origin. External activations without a matching internal request do not require a recent click.

The follow-up review identified that successful requests also suppressed later Command-Tab activations for the remainder of the suppression deadline. Successful completion now records a monotonic timestamp instead of just a Boolean. A keyboard focus intent after that completion can supersede the suppression; input at or before completion cannot. The completion callback still checks the request ID, and superseded, cancelled-after-mutation, or failed requests do not gain a successful-completion timestamp. Direct pointer targeting is unchanged. Concurrent activation during an outstanding write remains conservative because its origin is ambiguous.

The regression first failed with `swift test --filter keyboardActivationAfterCompletedFocusIsNotConsumed`. It now covers keyboard input before, at, and after completion. Existing delayed-echo cases go through the completion helper, and direct-click coverage includes both outstanding and completed requests. A desktop integration test completes a real focus write, injects normalized keyboard and activation events, and verifies that real AX resolution preserves the activation in the resulting snapshot. This is not a physical Command-Tab test. Validation passed 753 unit tests and the new desktop test with Accessibility available; the desktop suite had 22 passes, one skip, and the pre-existing floating-window stacking failure.

Review-fix validation: `swift build` and 751 tests passed. Desktop tests with Accessibility available produced 20 passes, one skip, and one floating-window stacking failure. The same assertion and window-order values failed on the unmodified PR head `9c20e96` in an isolated checkout, so this failure predates the review corrections. The installed build passed verification with its signing requirement preserved. Computer Use confirmed a Finder link revealing Helium's workspace with `activation=true accepted=true mouseIntent=false keyboardIntent=false`. Automated Cmd-Tab produced no observable transition, so it does not count as a successful Cmd-Tab smoke test.
