# Defi roadmap

## Phase 1 — Foundations

- [x] SwiftPM package boundaries
- [x] Pure model types and command parsing
- [x] Scrolling-column layout engine
- [x] Focus, move, stack, width, fullscreen, parking, and frame-diff primitives
- [x] Initial deterministic unit tests
- [x] Reducer and runtime state
- [x] TOML configuration and application rules
- [x] Unix-socket JSON-lines IPC
- [x] `defi` CLI
- [x] Headless daemon proof of concept

## Phase 2 — macOS platform

- [x] Accessibility window discovery through polling and AX event wakeups
- [x] Native app activation and focused-window synchronization
- [x] Real frame/target reconciliation
- [x] Mouse resize width learning
- [x] Topology-aware corner parking with delayed rollback repair
- [x] Parallel per-app AX writes with a global frame barrier
- [x] Accessibility frame application with unchanged-frame skips
- [x] Global hotkeys
- [x] Basic menu bar workspace and action UI
- [ ] Decorations and inactive-window dimming
- [x] Basic `launchd` development service integration

## Phase 3 — visual animation

- [ ] Transparent Metal overlay
- [ ] Public capture path prototype
- [x] Scrolling-column slide animation
- [ ] Gradient borders
- [ ] Blur

Public capture spike, 2026-07-28:

- Metal device and ScreenCaptureKit inventory available on development machine
- Screen Recording permission already granted
- prototype should capture static per-window textures before hiding real windows
- transparent, input-passthrough Metal overlay animates textures at display cadence
- AX coordinator commits final real frames before overlay removal
- keep current AX animation as permission-free fallback
- do not ship until focus, Dock, Cmd-Tab, mouse, mixed-scale displays, and capture
  failure recovery have desktop tests

## Phase 4 — polish

- [ ] Trackpad gestures
- [ ] Performance and edge-case suites
- [ ] Signing and notarization
- [ ] User documentation

## Phase 5 — post-V1

- [ ] Overview
- [ ] Settings UI
- [ ] Extension system

## Architecture constraints

- Platform frameworks never enter `DefiModel` or `DefiCore`.
- Every state mutation enters through normalized events and reducer paths.
- Frame planning skips unchanged windows.
- AX writes never drive animation frames.
- Public capture path ships first. Private WindowServer APIs remain optional fast path.
