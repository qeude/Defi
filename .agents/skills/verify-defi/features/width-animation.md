# Width change animation

## Sub-features

- `maximize-column` grow and shrink back, `cycle-width next|prev`.
- Stepped size writes per display step when the app's measured AX resize allows it; one write at progress 0 otherwise (never at the end).
- Edge-clamped growth (right-hand column): moved then resized, right edge pinned to the display edge.

## How to get to it (user POV)

Hotkeys for `maximize-column` and `cycle-width`, or the CLI.

## Driving it with the defi CLI

```sh
python3 script/desktop_lock.py --wait .agents/skills/verify-defi/resize_check.sh
```

Pass: every line `ANIMATED` (`intermediateWrites > 0`), `convergedMs` well under 400, `drift=0[]`, script exit 0. `JUMP-NO-STEPS` means the window jumped: read the matching `trace-*.log` (`size-commit` at start vs end, `cadence ... appliedIntermediateWrites=`).

Fixture-level proof (idle desktop only, probe waits for 10 s without input): `script/maximize_probe.py --bundle LABEL=path [--command cycle-width next] [--fixture-env DEFI_FIXTURE_RESIZE_MS=40] out/` reports first growth, time to full width, distinct widths, reversals and uncovered width; compare against a reference bundle. Also run the `native-compare` `scroll` and `workspace` guards from `script/performance_experiments.py` to prove navigation did not regress.

## Gotchas

- It resizes the focused window of the user's live session; run it under the desktop lock and never while the user works. Restore: the pairs return to the start width.
- A non-steppable (slow-resize) app may legitimately show 0 intermediate writes with a single size write at the start; confirm in the trace and treat as acceptable only if `size-commit` precedes the clock, not follows it.
- A single visible window has no neighbors sliding, so only stepped size makes it look animated.
- Unknown resize latency right after a daemon restart is calibrated by the first step; repeat once.
- Smoothness itself needs Computer Use or a screen recording at human timing; the script proves steps, not feel.
