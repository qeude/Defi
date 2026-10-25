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

Private macOS APIs are limited to optional read-only metadata, such as window
IDs, bounds, constraints, and corner radii, to read-only captures of window and
desktop pixels while Screen Recording is granted, and to Defi-owned surfaces
such as border overlays. Pixel captures fall back to public ScreenCaptureKit. Third-party windows are only observed through private APIs;
their position and size change only through public Accessibility.

- use private metadata only when it materially improves a user-visible result
  and a public-API fallback remains fully functional
- isolate private API use inside `DefiMacOS` behind a narrow backend interface
- resolve private symbols dynamically; missing or changed symbols must never prevent startup
- fall back immediately when optional private metadata is unavailable or invalid
- focus, lifecycle, Spaces, and compositor control remain on public macOS APIs

## Screen Recording

Window previews, the Overview zoom, and the window proxy overlay capture window
pictures and are on by default. They use the WindowServer window capture and fall
back to ScreenCaptureKit, which lights the menu bar recording indicator. Screen
Recording is requested once, before the Overview is presented; the overlay only
uses a permission already granted.
In the Overview, denial, revocation, or `overview.window_previews = false`
degrades to cards without errors, repeated prompts, or loss of the zoom
animation. Without the permission, the overlay is off and windows move at once.
Navigation,
focus, and window movement never depend on capture.

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

- acquire the per-user instance lock before creating the IPC socket
- use `defi service restart` for an installed build; never also use `open -n`
- before replacing an installed bundle, preserve its code-signing identity; set
  `DEFI_CODESIGN_IDENTITY` in the ignored `.env.local` when needed and verify
  the replacement has the same designated requirement, because macOS treats a
  changed requirement as different code and prompts for Accessibility and
  Screen Recording again
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
- keep vertical workspace transitions position-only and all-or-nothing; switch
  at once when the overlay cannot draw the motion
- settle latency-sensitive windows outside the speculative path while preserving their real targets, hidden state, and parking state

The scrolling workspace is one continuous horizontal strip.

- animate entering, visible, and leaving windows on the same overlay timeline; each native window moves once
- never impose an arbitrary cap that leaves an entering ribbon window unanimated
- never minimize managed windows to implement virtual workspaces
- park inactive-workspace windows through topology and Accessibility, never visual opacity
- park every hidden window, from an inactive workspace or an offscreen column,
  at its own size and height, leaving a one-point sliver on its own display, so
  any uncovered motion is a short horizontal slide; take the first of the side
  edge nearest the window, the other side edge, its bottom-right corner,
  bottom-left corner, top-right corner, top-left corner, and bottom edge that
  stays clear of every other display, else the one with the least overlap;
  macOS pulls a window onto the display under most of its width and
  keeps its title bar above that display's visible bottom, so judge each spot
  where macOS will leave it
- when display heights overlap, apply the temporary display staircase so
  partially visible columns never spill onto another display; commands and
  pointer crossings follow the desk the user arranged in System Settings
- never adopt Defi's own staircase as the desk; report
  `displayArrangement=ambiguous` until the user rearranges the displays
- restore the desk for the login session on shutdown, and never commit a
  staircase with session scope, including in test cleanup
- compute parking in the technical coordinates the daemon lays out in, so a
  parked window never sits under another display of the staircase
- keep native click, Dock, and Command-Tab focus compatible with virtual-workspace activation
- ignore redundant native focus on the already-selected window; no reflow or animation from a plain click

Each monitor owns an independent ordered workspace stack. A workspace is
globally unique and belongs to exactly one monitor at a time.

- preserve each monitor's own geometry, active workspace, focus, column widths, and scroll offset
- keep exactly one empty trailing ordinary workspace on every monitor; remove
  other empty ordinary workspaces only after they become inactive
- keep named workspaces persistent and globally unique; application rules may
  target names, never dynamic positions
- preserve workspace identity, ownership, affinity, order, membership, focus,
  widths, and scroll state across daemon restarts within one macOS session
- migrate workspaces temporarily after display loss and return them only after a
  confident monitor match; explicit monitor moves update affinity, automatic
  migration does not, and ambiguous matches leave workspaces on the fallback
  monitor
- never park one monitor's windows inside another monitor's visible or parking region
- reconcile widths, heights, targets, and parking after display connection, disconnection, or geometry change
- an active empty trailing workspace has no native focus target; stale native
  focus must not reactivate its previous workspace without newer human intent

## Configuration

Defaults live in code and `CONFIGURATION.md`. Example config contains user-specific overrides only.

Built-in defaults declare no named workspaces. `[workspaces].names` declares
persistent names only; ordinary workspaces come from the dynamic lifecycle.

No compatibility aliases before first stable release. Ask before preserving obsolete config.

## Verification

Choose verification by the changed behavior:

- Documentation-only changes: check the diff and any changed links or commands;
  no build, app launch, or desktop validation is needed.
- Code, tests, or build configuration: run `python3 script/verify.py local`.
  This runs `swift build`, non-desktop Swift tests, and workflow tests.
- Platform integration, daemon startup, packaging, or desktop-visible behavior:
  prepare with `python3 script/verify.py local --stage`, then run
  `python3 script/verify.py desktop <run-directory>` for installation and native
  tests. A focused `--filter DesktopE2ETests/testName` is appropriate when the
  affected interaction is covered; report that scope.
  `python3 script/verify.py full [--filter DesktopE2ETests/testName]` chains both
  phases and waits for the desktop automatically. Inspect progress with
  `python3 script/verify.py status [run-directory]`.
  Desktop tests use Defi-owned fixture windows only. A run with one display
  reports the two-display lane under `desktop.not_run`; that lane is not
  covered, so name it in the handoff. The render budget is an opt-in perf
  lane (`DEFI_E2E_PERF=1`), outside pass/fail.

Complete the applicable checks and fix failures caused by the requested change
before handoff. Report any check that could not run and why.

Use a separate worktree per concurrent code writer. Prepared bundles and results
live under the ignored `dist/verification/`; source drift invalidates a run.
Local verification never enables desktop E2E tests or installs the app.
Desktop verification checkpoints the running daemon's session stores and restores
them afterward, checking all monitor workspaces, logical focus, widths, scroll,
and managed-frame convergence. An incomplete restoration fails the run; inspect
the checkpoint artifacts before further desktop work. Native focus remains part
of Computer Use validation.

All installation, desktop tests, and Computer Use validation must share the
per-user desktop reservation. Scripts acquire it automatically and exit 75
when busy. Use `verify.py desktop <run-directory> --wait` to resume automatically
when available; sources and the bundle are rechecked after acquiring the reservation.
For Computer Use, hold
`python3 script/desktop_lock.py --wait bash` in a persistent interactive terminal,
run any installation from that shell, inspect the desktop while it remains
open, and exit the shell after restoration. Other agents can continue local
work. This lock coordinates cooperating agents, not the user's mouse or keyboard.

Platform smoke tests must report whether Accessibility permission was available.
Run real-desktop tests with `./script/test_desktop.sh`; it temporarily stops the
installed app so no second daemon can fight test frame writes, then restores it.

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
