# Ribbon animation benchmark

Run `python3 script/animation_benchmark.py` from the repository. The command
reserves the desktop, checkpoints Defi's session, switches to the `web`
workspace, samples the main display with ScreenCaptureKit, runs left and right
steps plus a rapid reversal, and drags the focused Dia window's right edge left
and back by 80 points. The resize uses public CoreGraphics mouse events and
checks the observed native width after each drag. Dia must be the focused app in
the selected workspace. Before/after `defi trace` and `defi status` are saved
separately, then the saved workspaces and focus are restored. Use
`--workspace NAME` to exercise a workspace with a focused Dia window or
`--output PATH` to choose a new artifact directory.

The helper stores timestamps and sampled grayscale values only; it does not
write screenshots or video. Artifacts include per-display-frame timestamps,
estimated horizontal shifts across four screen zones, phase markers, matching
before/after Defi traces and status, and a summary. Shifts at the search limit
are marked clipped and omitted from the summary. A high zone-offset spread suggests windows did not appear to
move together. Long gaps between correlated movement samples suggest visible
holds. Compare those estimates with AX submitted/applied writes in
`trace-after.txt`.

Pixel-shift estimates are approximate: changing page content, occlusion, resize,
and low-texture areas can weaken image correlation. Native width checks are the
resize correctness signal. ScreenCaptureKit can omit unchanged frames, so
callback gaps are evidence of captured image changes, not a certified display
refresh rate. Use the artifacts with a visual review; this tool does not claim a
guaranteed 120 FPS.


To test the private movement primitive independently, run
`python3 script/private_frame_probe.py`. It creates a mouse-ignoring transparent
panel owned by the probe process, moves it one pixel 24 times through
`SLSMoveWindow`, verifies each result with `SLSGetWindowBounds`, and restores its
starting point. Its function shape follows [yabai's SkyLight declaration](https://github.com/asmvik/yabai/blob/master/src/misc/extern.h); this is observed private ABI, not an Apple contract.
A helper-process failure cannot terminate the Defi daemon. This only tests a
Defi-owned surface; third-party windows remain on Accessibility unless the user
explicitly enables a future experimental backend.

See [the 2026-09-29 run notes](animation-results-2026-09-29.md) for the first
Dia measurements and private-probe outcome.
