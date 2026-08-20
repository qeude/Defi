# Defi performance initiative

This document records the performance and native-integration contract agreed
before implementation. The initiative targets macOS 26 and later.

## Outcome

Defi should feel like part of macOS because it remains stable and responsive,
not because it replaces the compositor. Priorities, in order, are:

1. No glitches, rollbacks, focus oscillation, or lost input.
2. Low input latency.
3. Smooth, refresh-aware motion.
4. Low CPU, memory, wakeup, and energy cost.

The public Accessibility path is the baseline. Screen Recording and captured
window overlays are out of scope. A private frame backend is authorized for
position and size only, remains experimental, disabled by default, and requires
explicit user opt-in. It is subject to the fallback policy in
[ADR 0001](docs/adr/0001-keep-macos-authoritative.md).

## Performance contract

For applications that can service Accessibility writes within the display
refresh budget:

- input event to planned native update: P95 at or below 4 ms
- input event to first observed native movement: P95 at or below 16.7 ms
- input event to converged final frame: P95 at or below 50 ms
- command intake never waits for a latency-sensitive application
- idle CPU and wakeups remain near zero and are reported with every benchmark

P50, P95, and P99 are reported. Optimization prioritizes visible tail latency
over improving an already-fast average. Remaining P99 outliers must be
attributed to Defi, an application, Accessibility, or macOS.

These measurements are not input-to-photon. They correlate the hardware event
timestamp with command planning, the first successful Accessibility write, the
first subsequently observed native frame, final convergence, and confirmed
focus. Installed-build validation separately checks the visible result.

## Interaction invariants

- Speculative navigation is latest-wins.
- A stale completion cannot restore older focus, layout, frames, or visibility.
- The latest human focus intent wins. Without new human intent, delayed or
  redundant platform events do not create focus changes.
- Confirmed native focus is followed without issuing a duplicate focus write.
- Focus moves as soon as its target has a safe visible frame; it does not wait
  for unrelated windows or the full animation.
- A latency-sensitive application receives a clean final frame instead of
  irregular intermediate frames, without degrading other applications.
- A command that changes no state performs no layout, persistence, menu, border,
  focus, or Accessibility work.
- Monitor state, layout work, animation, and parking remain isolated.

## Transient windows and pointer focus

- Dialogs, sheets, and modals inherit their owner's monitor and workspace when
  Accessibility exposes ownership.
- When ownership is unavailable, Defi uses an unambiguous focused window from
  the same application, then the transient window's own geometry.
- A background transient never activates a workspace by itself.
- While a modal is open, pointer focus may enter the modal or its descendants
  but cannot focus a window behind it.
- A real click, Dock action, or Command-Tab remains authoritative.
- Closing a modal does not synthesize focus; Defi waits for the next human action
  or confirmed native focus.
- Visible unmanaged popovers continue to block pointer focus from passing
  through to a managed window below them.

## Inter-monitor commands

The performance work is followed by two explicit commands:

```text
move-column-to-monitor left|right|up|down
move-window-to-monitor left|right|up|down
```

- Directions use physical monitor topology. No monitor in the requested
  direction is a strict no-op without frame or focus writes.
- The destination is the active workspace of the target monitor.
- A moved column retains its full stack and is inserted after the destination's
  focused column.
- A moved tiled window becomes an independent column; it never joins a stack
  implicitly.
- Pixel widths scale with the source-to-destination viewport ratio. Fractional
  widths retain their semantic value.
- Focus follows the moved window or column and the target monitor becomes active.
- Floating windows remain floating, keep their size, and are rebased inside the
  destination viewport.
- A transient cannot move independently; its owner and transient chain move as
  one unit.
- Cross-monitor motion uses the normal animation only while Accessibility keeps
  pace. Otherwise it commits one final frame.
- Generated column bindings use `<mod>-shift-h/j/k/l` for
  left/down/up/right. The single-window command is available to the CLI and
  custom key bindings without a generated shortcut.
- Local `move-column left|right` never implicitly crosses a monitor boundary.

## Benchmark matrix

Run every relevant interaction with:

- 1, 10, and 30 managed windows
- one fast application, one latency-sensitive application, and mixed processes
- one and two monitors
- 60 Hz and 120 Hz refresh rates when hardware permits
- ordinary navigation and short command bursts
- native click, Dock, and Command-Tab focus
- modal creation, hover, click, and dismissal
- monitor connection, disconnection, and geometry changes

Deterministic tests gate CI. Desktop performance runs are reproducible and
report regressions, but variable Accessibility timings do not create a flaky
automatic CI failure. An unexplained installed-build regression blocks manual
promotion.

## Delivery order

Implementation status: complete for the public Accessibility backend. Command
generations correlate input, planning, the first successful Accessibility
write, the first subsequently observed native frame, final convergence, and
confirmed focus. `defi status` reports bounded N/P50/P95/P99 samples, per-app
AX latency, and `defi trace` exposes individual correlated events. The installed
benchmark reports CPU and memory after returning to the initial focus.

1. Correlate input, planning, frame submission, observation, convergence, and
   focus; add percentile and resource reporting.
2. Remove repeated main-thread work, strict-no-op work, global layout work for a
   local change, and polling or blocking IPC from the input path.
3. Bound Accessibility tail latency per process while preserving final
   convergence and responsive command intake.
4. Enforce normalized focus authority, transient ownership, and modal pointer
   behavior.
5. Add and validate the two inter-monitor commands.
6. Evaluate the authorized private position/size backend where measured
   public-API limits violate the contract; ship it only when a normal signed
   process can mutate third-party frames and measurably improve the tail.

## Measured result

The final installed-build run on 2026-08-19 used one 2560×1362 viewport at
120 Hz, 14 managed windows across nine applications, and 20 ordinary column
navigation commands. It reported:

| Metric | P50 | P95/P99 |
| --- | ---: | ---: |
| input to plan | 1.53 ms | 2.97 ms |
| input to first successful AX write | 7.96 ms | 24.35 ms |
| input to first fresh frame observation | 84.00 ms | 160.51 ms |
| input to fresh final-frame convergence | 84.00 ms | 160.51 ms |
| input to confirmed focus | 111.79 ms | 283.35 ms |

The Defi-owned planning budget is met. The remaining tail begins after frame
submission and is attributed per process by `axAppDetails`; in this run the AX
EMA ranged from 0.9 to 13.9 ms. A fresh frame observation requires a later
public AX snapshot, so it is intentionally slower than the first successful
native write and is not a proxy for first pixel. Measuring input-to-photon would
require the rejected Screen Recording permission. Idle sampling after
settlement reported 0.0% CPU and 15 MiB resident memory with the timer at 2 Hz.

Validation covered the full deterministic suite and all 17 real-desktop tests
with Accessibility permission, including hotkey intake while the MainActor is
blocked, native focus, rapid latest-wins focus, pointer tracking, cursor warp,
animation convergence, one-pixel anchors, parking, and rollback repair. A
partial IPC client held open for three seconds did not delay a concurrent status
request (47 ms).

Only one 120 Hz display was available. Two-display routing, disconnected-display
migration, physical directions, width scaling, floating rebasing, transient
chains, and no-target no-ops are covered deterministically; physical two-display
and 60 Hz runs remain hardware-dependent validation, not an implementation gap.

The private frame path was evaluated on the signed installed build with
Accessibility permission. `SLSMoveWindow` succeeded on a Defi-owned probe
window but returned `CGError` 1000 for a third-party window. The group-move and
transform variants returned success without changing the third-party bounds or
transform. Defi therefore keeps the public backend instead of shipping an
opt-in that cannot improve performance in a normal user session. ADR 0001 still
permits a future experimental backend if macOS exposes a usable capability; it
must retain the same public fallback and prove a lower tail without stability
regressions.

## Completion

The initiative is complete when the contract holds on benchmarked hardware,
the remaining P99 outliers are attributed, no avoidable work remains on the
input path, and further improvement would require a rejected permission or
fragility.

Before handoff, run:

```sh
swift build
swift test
./script/build_and_run.sh --verify
./script/test_desktop.sh
```

Installed-build checks exercise realistic clicks and short command sequences,
restore the initial workspace, and leave exactly one `defi-daemon` process.

Native fullscreen, trackpad gestures, overview, Settings UI, and visual polish
are outside this initiative.
