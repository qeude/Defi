# Overview implementation plan

Status: implemented and validated on 2026-08-24.

This plan implements the Overview defined in `CONTEXT.md` and the capture
boundary accepted in ADR 0003. Each phase lands as a revertable commit and
keeps the tree green.

## Goal

Provide a keyboard-first, interactive reduced presentation of every configured
workspace on every monitor. Each monitor keeps a vertical stack of full-width,
workspace ribbons. Each ribbon keeps a uniformly scaled view of its horizontal
scrolling strip. Optional window previews add captured pixels without changing
behavior.

## Product contract

- Opening the Overview creates one surface per connected monitor.
- Every configured workspace is present, including empty workspaces.
- Each workspace uses the full monitor width as a compact horizontal ribbon.
- Each strip keeps a small leading inset; overflowing strips retain their
  horizontal viewport and overflow controls.
- The active workspace is centered. Only workspaces intersecting the monitor
  are rendered.
- Vertical navigation moves through the workspace stack. Horizontal navigation
  moves a temporary Overview viewport through one scrolling strip.
- Moving the Overview viewport never changes native frames or the workspace's
  real scroll offset.
- A simple click focuses its window or workspace and closes the Overview.
- Keyboard navigation changes real focus immediately and keeps the Overview
  open.
- A drag changes only the presentation until drop. Drop applies one atomic
  runtime mutation, focuses the moved window, and keeps the Overview open.
- The projected ribbons animate after drop while native windows receive one
  final layout pass beneath the Overview.
- Dragging near the top or bottom advances the workspace stack visually at a
  bounded fixed cadence. It performs no native focus or parking work before
  drop.
- A click, scroll, or drop on another monitor makes that monitor active. Hover
  alone does not.
- Command-Tab, a Dock activation, screen lock, sleep, or a display topology
  change closes the Overview. No stale completion may reopen it or restore an
  earlier focus.

## Window treatment

- Tiled windows retain their column and stack order.
- Floating windows render above tiled windows at their logical relative frame.
- A floating window remains floating when moved to another workspace or
  monitor.
- Transient windows render with their owner and cannot move independently.
- Native fullscreen windows render at their saved logical placement. A click
  closes the Overview and activates the fullscreen window. Drag is disabled
  while native fullscreen remains active.
- Minimized and unmanaged windows are absent because they do not belong to a
  Defi workspace.

## Input

- Add `toggle-overview` to command parsing, configuration validation, IPC, and
  the CLI.
- Bind `<default_modifier>-o` by default while allowing the normal `[keys]`
  override.
- While open, capture these unmodified keys through the existing event tap:
  - Left and Right navigate columns.
  - Up and Down navigate the stack, then adjacent workspaces.
  - Return chooses the current selection and closes.
  - Escape closes without another focus change.
- Existing configured Defi shortcuts continue to work.
- Pointer input supports click, left-button drag, vertical wheel navigation,
  horizontal scroll, and right-button horizontal drag.
- Precise trackpad deltas move the Overview viewport directly along their
  dominant axis, preserve macOS natural scrolling, and use the same bounds as
  keyboard paging. This phase adds no custom inertia, hot corner, or
  four-finger gesture.

## Configuration and permission

```toml
[overview]
window_previews = false
```

- `false` performs no capture preflight, permission request, or ScreenCaptureKit
  content query.
- `true` requests Screen Recording on the next Overview opening when permission
  is missing. Configuration loading never presents the system dialog.
- The Overview opens immediately with fallback cards while the permission
  request is pending.
- If capture becomes available immediately, previews populate the current
  session. Otherwise they populate a later session.
- Denial or revocation keeps the full fallback behavior and does not cause a
  repeated automatic request.
- Reloading the value to `false` cancels pending capture work and discards the
  in-memory cache.

## Module boundaries

`DefiModel`

- Add the presentation-only `toggleOverview` command and parser support.
- Keep identifiers and serializable command syntax free of AppKit and capture
  types.

`DefiCore`

- Define immutable Overview projection inputs and outputs.
- Compute full-width ribbon rectangles, uniformly scaled column and stack
  geometry, culling, hit tests, and drop targets.
- Keep ribbon height fixed relative to the Overview height for this version.
- Cover the geometry without Accessibility permission.

`DefiConfig`

- Add `OverviewConfig` with `windowPreviews = false`.
- Decode `[overview].window_previews` without aliases.
- Add and validate the default toggle binding.

`DefiRuntime`

- Accept explicit focus and drop intentions identified by `WindowID` rather
  than relying on the previously selected window.
- Validate the current source location and exact destination monitor,
  workspace, column index, and stack index at commit time.
- Apply tiled, stacked, floating, transient-owner, and cross-monitor movement
  atomically.
- Reject stale window IDs, missing monitors or workspaces, invalid indices, and
  native fullscreen moves without partial mutation.
- Reuse the existing focus, width, parking, and descendant movement policies.

`DefiMacOS`

- Own the AppKit panels, drawing, pointer interaction, modal keyboard capture,
  animation progress, session preview cache, and ScreenCaptureKit calls.
- Create one borderless nonactivating panel per monitor. Keep panels above
  application windows but below macOS system UI so Command-Tab, the menu bar,
  and Dock remain usable.
- Draw a native dark glass backdrop, full-width workspace ribbons, focus
  indication, app icon, title, and optional preview.
- Animate the set of panels with one short scale and fade. Do not morph
  individual captured windows.
- Keep the controller independent from `DefiRuntime`; expose callbacks carrying
  model identifiers and pure intent values.

`DefiDaemon`

- Build immutable snapshots from `RuntimeState`, monitor geometry, and the
  existing logical floating-frame cache.
- Wire Overview callbacks to runtime mutations and normal layout/focus effects.
- Reconcile window creation, removal, metadata changes, and focus changes into
  the open session.
- Close the session on external focus intent or display topology change.
- Do not move the daemon's existing active-monitor and floating-frame ownership
  as part of this feature. The general runtime-domain migration remains a
  separate plan.

The data flow is:

```text
Runtime state + monitor geometry + floating targets
  -> immutable Overview snapshot
  -> pure projection
  -> AppKit panels

Panel intent
  -> daemon routing
  -> DefiRuntime validation and mutation
  -> normal focus/layout effects
  -> next immutable snapshot

ScreenCaptureKit result
  -> session-generation check
  -> presentation cache only
  -> panel repaint
```

## Drop rules

- Dropping in either outer quarter of a column creates a neighboring column.
- Dropping in the central half inserts into its stack according to pointer
  height.
- Dropping a single-window column onto its own card leaves the column unchanged.
- Dropping into an empty workspace creates its first column.
- Floating drops retain floating classification and store a frame relative to
  the target viewport.
- The same rules apply across monitors.
- A source that closes or changes identity during drag cancels the drag.
- A target monitor disappearing closes the complete Overview through the
  display-change rule.
- This version does not convert tiled and floating state during drag and does
  not create workspaces dynamically.

## Preview capture

- Add `NSScreenCaptureUsageDescription` to the app metadata.
- Use public ScreenCaptureKit APIs only.
- Query shareable content with offscreen windows included, then capture each
  requested window independently with `SCScreenshotManager`.
- Request previews only for cards intersecting a rendered workspace and
  viewport. Capture a window once when it first becomes visible in the current
  session.
- Run at most two captures concurrently.
- Size the image to its rendered card instead of capturing native resolution.
- Store images in memory by session generation and `WindowID`; never write them
  to disk. Retain at most 16 MiB of validated previews between sessions and
  discard a remembered image when its fresh capture fails.
- Discard late results when the session, window identity, or requested size no
  longer matches.
- Use the fallback card for permission denial, protected content, empty images,
  stale results, and errors.
- Fade captured previews over fallback cards, unless Reduce Motion is enabled,
  and progressively blur only the title area for readability.
- Capture no audio or cursor and create no persistent `SCStream`.

## Implementation phases

### 1. Commands and configuration

- Add command parsing, CLI routing, default binding, config decoding, validation,
  and documentation.
- Add focused parser and config tests.
- No UI or capture code in this phase.

### 2. Pure projection and runtime intentions

- Add Overview geometry, culling, hit testing, viewport navigation, and drop
  target calculation in `DefiCore`.
- Add explicit focus and atomic drop handling in `DefiRuntime`.
- Test empty workspaces, stacks, floating windows, transients, fullscreen
  rejection, stale intents, and cross-monitor moves.

### 3. Functional Overview without capture

- Add panels, rendering, global toggle, modal keyboard handling, pointer input,
  per-monitor viewport state, simple animation, and fallback cards.
- Wire live snapshots and closing rules through the daemon.
- Verify that pan and drag perform zero Accessibility writes before a committed
  action.

### 4. Optional previews

- Add permission handling, visible-first scheduling, bounded screenshot capture,
  cache invalidation, and generation checks.
- Add unit tests around scheduling and stale completion policy using injected
  capture closures rather than a speculative backend hierarchy.
- Document that a full-display screen share can reveal the Overview and its
  previews.

### 5. Hardening and installed validation

- Expose Overview open state, panel count, preview configuration, permission
  state, in-flight captures, cache count, and failures through status or trace.
- Add accessibility labels and respect the system Reduce Motion setting.
- Exercise click, keyboard navigation, drag, cross-monitor drop, external focus,
  permission denial, and display changes with realistic timing.
- Confirm no focus rollback, parking leak, stale image, lost input, or duplicate
  daemon.

## Acceptance checks

- With `window_previews = false`, opening the Overview performs no capture API
  call and presents no privacy dialog.
- Denied Screen Recording produces the same navigation, focus, and drop results
  as granted permission.
- Overview opening and input never wait for Accessibility or capture work.
- Pan and in-progress drag produce no native frame or focus writes.
- Each completed drop produces one validated runtime mutation.
- A stale capture or focus completion cannot affect a newer session.
- Each monitor shows and mutates only its own workspace copy unless an explicit
  cross-monitor drop commits.
- Each workspace spans the monitor width and preserves window proportions in a
  uniformly scaled horizontal ribbon with a consistent leading inset.
- Clicking a card closes the Overview and leaves the intended native window
  focused.
- Keyboard navigation keeps the Overview open and uses latest-wins focus.
- Display changes and external app activation close every panel exactly once.
- Fullscreen, transient, floating, empty-workspace, and protected-content cases
  preserve their documented fallback behavior.

## Verification

Run after each phase:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

For phases 3 through 5, also run `./script/test_desktop.sh` and validate the
installed build with Computer Use. Restore the initial workspace and confirm
exactly one `defi-daemon` process remains.

## Out of scope

- Live or periodically refreshed window previews.
- Per-window zoom morphs.
- Hot corners and custom trackpad gestures.
- Dynamic workspace creation or reordering.
- Tiled/floating conversion during drag.
- Minimized or unmanaged windows.
- Overview zoom, colors, or animation configuration.
- Native macOS Spaces control.
- The general runtime-domain migration.
