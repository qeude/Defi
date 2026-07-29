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
- private WindowServer APIs

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

## Git

Use conventional branch names and English commit/PR text. Preserve user changes. Never revert unrelated work.
