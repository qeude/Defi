# Animation investigation: 2026-09-29

On a 120 Hz display, the Dia `web` workspace trace captured one Accessibility
position write taking 29.36 ms (generation 12), over three 8.33 ms refresh
budgets. The surrounding cadence trace reported a maximum 8.38 ms gap between
intermediate writes, so the long application call is a concrete source of
latency even though submission itself was fast.

Across repeat runs, Dia position writes peaked at 55.19 ms during a single-left
step and 21.64 ms during the final rapid-reversal run. Both exceed the 8.33 ms
120 Hz interval; the variation also shows why one capture is not a performance
guarantee.

The repeat run requested an 80-point narrowing, but Dia's native window width
changed from 1684 to 1611 points, a 73-point decrease and a 7-point undershoot.
The reverse drag returned it exactly to 1684 points. After the sequence Defi
reported `drift=0`, `resize=none`, and no pending frame writes.

ScreenCaptureKit's first run had a 66.67 ms callback gap during a single right
step; the final repeat had a 16.67 ms maximum in that phase. Rapid reversal's
largest gap between correlated movement samples fell from 191.67 to 158.33 ms.
These are image-correlation estimates, not presented-frame measurements:
unchanged frames can be omitted, and page content can weaken matching. The
mouse-resize phase produced one usable motion sample, so its visual smoothness
is not quantified by this correlator. The final repeat-run samples and trace
are in the ignored, local-only `dist/benchmarks/dia-run-with-resize-retry-20260929/`
artifact directory. The earlier run with the 55.19 ms write is in the ignored,
local-only `dist/benchmarks/dia-run-with-resize-20260929/` directory. The files
are not available from a clean checkout; the key measurements are recorded above.

The Defi-owned-panel `SLSMoveWindow` probe once verified 24 moves with
sub-millisecond timings, then failed on two repeat attempts: both private calls
returned success, but the immediately read bounds did not match the requested
position. That result is not repeatable enough to justify a runtime backend.
The probe remains an isolated experiment and does not mutate third-party
windows. The helper now reports failures cleanly and saves stdout, stderr, and
exit status alongside each run.
