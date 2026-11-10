# Defi Agent Notes

Defi remains macOS-native, Niri-inspired, and scrolling-columns only. Before
inventing a behavior Niri already has, check how Niri does it.

Prefer the smallest model that makes the correct behavior unsurprising. Remove
complexity that no longer earns its place instead of preserving it. If a rule
here fights the task in front of you, say so plainly and get the maintainer's
sign-off before breaking it.

## Vocabulary

- **maintainer** means the developer you are talking to. Their Mac is also a
  test bench: its desktop, installed Defi, and `config.toml` are in daily use.
- **user** means anyone running Defi. Speak of the maintainer's desktop when you
  mean the real machine you work on.
- **installed build** means `~/Applications/Defi.app` and its single
  `defi-daemon`. Several agents share it; whoever installs last replaces the
  others' builds.
- Domain terms (monitor, desk, workspace, column, parking) follow `CONTEXT.md`.

## Ways to hurt the maintainer's session

1. **Showing things on their desktop.** `make verify` must stay invisible: a
   test that orders a real window or panel on screen runs only in CI or with
   `DEFI_E2E=1`. Run repros in the `defi-e2e` VM, or under the desktop
   reservation described under Verification.
2. **Typing into the frontmost app.** Synthetic key events posted to the global
   HID tap reach whatever app is frontmost, with any modifier still held: a
   stray Command once closed windows and quit T3 Code. Post keys to the target
   process, and load URLs with `open`.
3. **Replacing someone else's build.** Before installing, state which commit you
   install; afterwards report it and confirm exactly one `defi-daemon`. Install
   with the identity the installed app already uses (see Runtime rules), or
   macOS prompts again for Accessibility and Screen Recording.
4. **Filling the disk.** Every `xctrace record` leaves a 3-7 GB
   `instruments*.ktrace` in `$TMPDIR`, even after the `.trace` is deleted. Delete
   traces, recordings, and VM artifacts as soon as you have read them.
5. **Editing their configuration.** Never change the maintainer's
   `~/.config/defi/config.toml`; point the daemon at a scratch config instead.

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
desktop pixels while Screen Recording is granted, to reading the global hotkey
operating mode, and to Defi-owned surfaces such as border overlays. Pixel captures fall back to public ScreenCaptureKit. Third-party windows are only observed through private APIs;
their position and size change only through public Accessibility.

- use private metadata only when it materially improves a user-visible result
  and a public-API fallback remains fully functional
- isolate private API use inside `DefiMacOS` behind a narrow backend interface
- resolve private symbols dynamically; missing or changed symbols must never prevent startup
- fall back immediately when optional private metadata is unavailable or invalid
- focus, lifecycle, Spaces, and compositor control remain on public macOS APIs
- in shipped builds, Defi works with System Integrity Protection enabled and
  injects no code into another process
- prototypes may try any other private API within those two limits; one ships
  only with a gain measured beyond noise, a complete public fallback, and a
  reason recorded in [macOS authority](docs/internals/macos-authority.md)

## Screen Recording

Window previews, the Overview zoom, and the window proxy overlay capture window
pictures and are on by default. They use the WindowServer window capture and fall
back to ScreenCaptureKit, which lights the menu bar recording indicator. Screen
Recording is requested once Accessibility is granted, and again before the
first Overview of a session if still missing.
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

Out of scope:

- BSP layouts
- native macOS Spaces control
- compositor replacement
- mouse-first shell

## Hit every surface

The most common defect in Defi is a change that works on the path you tested
and is missing everywhere else. Before calling a behavior change done, walk
this list and say which entries applied:

- **Entry points.** Hotkey, `defi` CLI and IPC, event stream, menu bar,
  Settings, cheatsheet, Overview, mouse, drag, and trackpad gestures. A command
  that works in the strip must also be handled, or deliberately refused, while
  the Overview is open.
- **Settings and docs.** Every user-facing option is reachable in Settings, not
  only in TOML, with its default in code and in `CONFIGURATION.md`. The README
  explains why each permission is needed.
- **Displays.** One and two displays, the display staircase, disconnection and
  reconnection, and moves across monitors. When the two-display lane did not
  run, say so.
- **Permissions.** Accessibility and Screen Recording granted, denied, and
  revoked. Never prompt for a permission that is already granted.
- **Defaults and modifiers.** A changed default, binding, or `mod` combination
  reaches the cheatsheet, Settings, tests, and existing configs. A config valid
  for this build may reach an older installed build; fail with a clear error.
- **Reverse states.** A way in needs a way out: stack and unstack, enter and
  leave, show and hide.
- **Restart.** State must survive `defi service restart` within a session, and
  caches must not need a restart to clear.
- **Docs.** Check whether `docs/internals/` or `CONFIGURATION.md` became wrong.

## Runtime rules

All state mutation passes through `DefiRuntime`.

Run exactly one `defi-daemon` instance per user session. Multiple daemons create
competing event taps, socket ownership, AX writes, and visible layout glitches.

- acquire the per-user instance lock before creating the IPC socket
- use `defi service restart` for an installed build; never also use `open -n`
- before replacing an installed bundle, preserve its code-signing identity and
  verify the replacement has the same designated requirement, because macOS
  treats a changed requirement as different code and prompts for Accessibility
  and Screen Recording again. The scripts reuse the installed app's certificate
  unless `DEFI_DEVELOPMENT_TEAM` is set; when `.env.local` sets it, set
  `DEFI_CODESIGN_IDENTITY` to the installed app's identity (`'Defi Release'` on
  the maintainer's Mac)
- stop the current instance before replacing the installed app bundle
- after build/run verification, confirm exactly one `defi-daemon` process remains

Managed tiled windows fill vertical workspace space. Width changes reflow siblings. Inactive workspace windows park offscreen. Active-workspace focus stays explicit.

AX notifications drive discovery, with bounded delayed reads for apps that report late. Keep cadence bounded and frame writes diffed.

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

- animate entering, visible, and leaving windows on the same overlay timeline
- move each native window once per motion; a strategy with more moves must show
  fewer dropped frames and no window placed visibly in two steps
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
  pointer crossings follow the desk the user arranged in System Settings;
  lift the staircase while System Settings is the active app so Displays
  shows and edits the desk
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

## Documentation

Most code changes need no documentation change; agents can read the code.

- `docs/internals/` holds architectural decisions and their reasons,
  constraints that span modules, and traps the source does not reveal. Before
  adding a paragraph, ask what a maintainer would get wrong without it.
- Keep a local reason in a short code comment; link to source instead of
  copying it. Leave feature catalogs, field lists, and PR summaries to the code
  and git history.
- When a documented decision or constraint changes, rewrite or remove the
  affected text in place, so each page describes Defi as it is now.
- Track plans and active work in GitHub issues. A merged PR is the
  implementation record. Keep temporary research outside the repository.
- List every internal page in `docs/README.md`.

## Verification

Choose verification by the changed behavior:

- Documentation-only changes: check the diff and any changed links or commands;
  no build, app launch, or desktop validation is needed.
- Code, tests, or build configuration: run `make verify`.
  This runs `swift build`, non-desktop Swift tests, and workflow tests.
- Platform integration, daemon startup, packaging, or desktop-visible behavior:
  `make verify-desktop FILTER='DesktopE2ETests/(testA|testB)$'` prepares a signed
  bundle, waits for the desktop, then installs it and runs native tests. By
  default, run only the desktop tests covering the interactions you changed.
  Widen the selection, up to the whole suite, wherever you suspect a side
  effect, or when the change touches shared platform plumbing no specific test
  maps to. Report the chosen tests and why. To prepare first and take the
  desktop later, run `script/verify.sh local --stage`, then
  `script/verify.sh desktop <run-directory> --filter …`. Before tagging a
  release, run `make verify-desktop` unfiltered on the release commit; it
  certifies the batch of changes the scoped runs let through. Also run
  `make perf-release` on the version bump and commit `perf/releases/v<version>.*`. Inspect progress
  with `make verify-status` or `script/verify.sh status [run-directory]`.
  Desktop tests use Defi-owned fixture windows only. A run with one display
  reports the two-display lane under `desktop.not_run`; that lane is not
  covered, so name it in the handoff. The render budget is an opt-in perf
  lane (`DEFI_E2E_PERF=1`), outside pass/fail.

### Tests

- Fix a logic, state, or protocol bug with a test that fails on `main` first,
  then the fix. A purely visual bug is proven by before and after recordings of
  the installed build instead of a test.
- Proof is observed behavior: a passing test that fails without the change, or
  a recording of the installed build. "Verify passes" or "seen in the code" does
  not show that a reported bug is fixed; reproduce it first.
- Extend before you add: when an existing test or table covers the behavior,
  add a case there. Test at the lowest layer that fails, once.
- Drive time with a virtual clock, such as `VirtualObservationClock`, and await
  the event or state that marks the milestone. Sleeps, polling loops, and
  wall-clock deltas make tests slow and flaky; keep them to desktop E2E and
  performance lanes.
- Leave out tests for what types already guarantee, trivial logic, and copy.

Complete the applicable checks and fix failures caused by the requested change
before handoff. Report any check that could not run and why.

When `tart list` shows a local `defi-e2e` VM, prefer `script/test_vm.sh` for
iterating on desktop tests, so the user keeps their desktop. It queues on its own VM lock rather than the
desktop reservation. It complements `verify.sh desktop`, which remains the certifying lane. See
`CONTRIBUTING.md` for its limits.

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
when busy. Use `verify.sh desktop <run-directory> --wait` to resume automatically
when available; sources and the bundle are rechecked after acquiring the reservation.
For Computer Use, hold
`script/desktop_lock.sh --wait bash` in a persistent interactive terminal,
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

## Style

Take ideas from other window managers, but name only Niri in the repository and
adapt ideas rather than copying code.

Default to no comment. Write one only for a constraint, a platform quirk, or an
invariant the code cannot show, in one line where you can. Leave history and
the fix you just made to the commit message.

## Agent skills

### Issue tracker

Issues live in GitHub Issues; use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default canonical triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repo using root `CONTEXT.md` and `docs/internals/`. See `docs/agents/domain.md`.
