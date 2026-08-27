# Defi Agent Notes

Defi remains macOS-native, Niri-inspired, and scrolling-columns only.

## Golden rule

Keep Defi fast, deterministic, stable, and glitch-free.

- avoid unnecessary Accessibility writes
- skip unchanged frames
- prevent layout feedback loops
- preserve per-monitor isolation
- normalize platform events before state mutation
- keep commands and layout testable without Accessibility permission

## Architecture boundaries

- `DefiModel`: pure data and command parsing
- `DefiCore`: pure layout engine
- `DefiConfig`: TOML parsing, defaults, validation, app rules
- `DefiRuntime`: reducer and workspace routing
- `DefiIPC`: Unix-socket protocol
- `DefiMacOS`: AppKit, Accessibility, CoreGraphics, hotkeys
- `DefiDaemon`: daemon wiring
- `DefiCLI`: `defi` command

Never import AppKit, ApplicationServices, or CoreGraphics from pure modules.

## Private platform API policy

Use private macOS APIs only when public APIs have been demonstrated unable to
meet a user-visible correctness, stability, or latency invariant.

- isolate private API use inside `DefiMacOS` behind a narrow backend interface
- resolve private symbols dynamically; missing or changed symbols must never prevent startup
- always keep a fully functional, tested public-API fallback
- probe private capabilities using Defi-owned surfaces, never by mutating user windows
- downgrade to the public backend for the rest of the session after a private operation fails
- expose the active backend and fallback count through status or telemetry
- third-party position and size mutation is approved only for Defi's
  experimental frame backend after explicit user opt-in; keep it disabled by
  default, while focus, lifecycle, Spaces, and compositor control remain on
  public macOS APIs

## Product shape

Keep:

- scrolling columns
- virtual workspaces
- per-monitor isolation
- keyboard and CLI control
- minimal config by default

Exclude from MVP:

- BSP layouts
- native macOS Spaces control
- compositor replacement
- mouse-first shell

## Runtime rules

All state mutation passes through `DefiRuntime`.

Run exactly one `defi-daemon` instance per user session. Multiple daemons create
competing event taps, socket ownership, AX writes, and visible layout glitches.

- check for an existing daemon or loaded `com.quentin.defi` LaunchAgent before launch
- when the LaunchAgent is loaded, use `defi service restart`; never also use `open -n`
- stop the current instance before replacing the installed app bundle
- after build/run verification, confirm exactly one `defi-daemon` process remains

Managed tiled windows fill vertical workspace space. Width changes reflow siblings. Inactive workspace windows park offscreen. Active-workspace focus stays explicit.

Poll-based discovery is acceptable for MVP. Keep cadence bounded and frame writes diffed. AX notifications may replace polling later without changing pure runtime contracts.

## Navigation, focus, and parking invariants

Scrolling navigation must remain speculative and latest-wins.

Preserve these outcomes without freezing a specific implementation:

- stale asynchronous completions must never restore an older focus, frame, layout, or visibility state
- observed real frames and logical targets must converge without feedback loops; neither optimistic targets nor delayed native events are authoritative in every situation
- keyboard capture and command intake must remain responsive while Accessibility or layout work is pending
- scrolling animation must remain monotonic, refresh-aware, and free from abrupt time-based catch-up jumps
- parking must converge and self-repair after delayed application behavior without leaking parked windows into visible monitor regions

Current strategy may evolve when replacement preserves the same outcomes and tests:

- classify AX latency dynamically per process with stable transitions; never hardcode slow-app behavior for Xcode or any other application
- coalesce transient focus changes during rapid navigation; commit real AX focus only for the final target
- keep focus writes asynchronous so slow applications cannot block command intake
- keep horizontal navigation position-only unless a replacement proves synchronous size work cannot enter the input path
- settle latency-sensitive windows outside the speculative path while preserving their real targets, hidden state, and parking state

The scrolling workspace is one continuous horizontal strip.

- animate entering, visible, and leaving windows on the same movement timeline when their AX lane permits it
- never impose an arbitrary cap that leaves an entering ribbon window unanimated
- never minimize managed windows to implement virtual workspaces
- park inactive-workspace windows through topology and Accessibility, never visual opacity
- keep same-workspace offscreen columns at their verified one-pixel strip anchors
- keep native click, Dock, and Command-Tab focus compatible with virtual-workspace activation
- ignore redundant native focus on the already-selected window; no reflow or animation from a plain click

Each monitor owns an independent copy of the configured virtual workspace set.

- preserve each monitor's own geometry, active workspace, focus, column widths, and scroll offset
- never park one monitor's windows inside another monitor's visible or parking region
- reconcile widths, heights, targets, and parking after display connection, disconnection, or geometry change

## Configuration

Defaults live in code and `CONFIGURATION.md`. Example config contains user-specific overrides only.

No compatibility aliases before first stable release. Ask before preserving obsolete config.

## Verification

Before handoff:

```sh
swift build
swift test
./script/build_and_run.sh --verify
```

Platform smoke tests must report whether Accessibility permission was available.
Run real-desktop tests with `./script/test_desktop.sh`; it temporarily stops the
LaunchAgent so no second daemon can fight test frame writes, then restores it.

For user-visible changes to animation, focus, parking, hotkeys, native Dock or
Command-Tab interactions, mouse behavior, or multi-monitor routing, also validate
the installed build with Computer Use.

- exercise realistic human timing, including ordinary clicks and short navigation sequences; do not rely only on synthetic command bursts
- correlate visual behavior with `defi status` and `defi trace` when diagnosing timing or rollback issues
- confirm no visible glitch, rollback, lost input, focus oscillation, or parking leak in the changed interaction
- restore the user's initial workspace after validation
- confirm exactly one `defi-daemon` remains after validation
- skip Computer Use for documentation-only changes, pure logic, or configuration parsing without desktop-visible behavior

## Git

Use conventional branch names in `type/short-kebab-description` form. Prefer
`feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, or `chore` as type.
Write repository documentation, comments, commit messages, and PR text in English.
Preserve user changes. Never revert unrelated work.

## Agent skills

### Issue tracker

Issues live in GitHub Issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repo using root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.
