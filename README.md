# Defi

[![CI](https://github.com/qeude/Defi/actions/workflows/ci.yml/badge.svg)](https://github.com/qeude/Defi/actions/workflows/ci.yml)

Defi is a native macOS scrolling-column window manager inspired by
[Niri](https://github.com/YaLTeR/niri). It is built around one simple idea:
your desktop is a continuous horizontal ribbon, not a grid of disconnected
layouts.

Defi keeps several windows visible as scrolling columns. Keyboard navigation
moves through the ribbon; virtual workspaces keep separate ribbons per monitor.
Windows remain native macOS windows, so normal clicks, Dock activation, and
Command-Tab still work.

Defi is also built with a performance-first goal: to do the best possible
within macOS's constraints.

> **Status: `0.1.0-alpha`**  
> Defi is experimental software. Behavior and configuration may change before
> the first stable release.

## What Defi brings

- **Scrolling columns** — keep neighboring context visible while moving through
  a wide desktop.
- **Per-monitor workspaces** — every display owns its own workspace set,
  focused window, widths, and scroll position.
- **Keyboard-first control** — focus, move, stack, resize, maximize, and switch
  workspaces without reaching for a mouse.
- **Native focus and frame reconciliation** — Defi follows real macOS focus and
  window frames instead of assuming every request succeeds immediately.
- **Floating windows** — mix tiled columns with floating application windows.
- **Mouse interaction** — focus follows the pointer when enabled; title-bar
  dragging reorders columns and stacked windows.
- **Application rules** — route apps to workspaces and choose tiling behavior
  with a small TOML configuration.
- **Menu bar and CLI controls** — inspect state, trace behavior, and control
  Defi from the menu bar or Unix-socket CLI.
- **Topology-aware workspaces** — inactive windows park outside visible monitor
  regions and return when their workspace becomes active.

## Install the alpha

Download [Defi v0.1.0-alpha](https://github.com/qeude/Defi/releases/tag/v0.1.0-alpha)
and open `Defi-0.1.0-alpha.dmg`. Drag `Defi.app` to `Applications`, then launch
it.

The alpha DMG is signed with an Apple Development certificate but is not yet
notarized. On first launch, macOS may require **Open Anyway** in System Settings
→ Privacy & Security → Security.

### Required permission

Defi requires macOS **Accessibility** permission to discover, move, resize,
focus, and park windows:

1. Open System Settings → Privacy & Security → Accessibility.
2. Enable `Defi`.
3. Restart Defi if it was already running.

Without this permission, Defi can start but cannot manage application windows.

Defi targets macOS 14 or newer. No configuration file is required: built-in
defaults provide workspaces `1` through `9` and Option-based shortcuts.

Default keyboard bindings use Option. The complete shortcut and command
reference lives in [CONFIGURATION.md](CONFIGURATION.md).

## Configuration

Default path:

```text
~/.config/defi/config.toml
```

Defi works without this file. Start from [defi.example.toml](defi.example.toml)
when you need named workspaces, custom hotkeys, application rules, or layout
overrides. Full reference lives in [CONFIGURATION.md](CONFIGURATION.md).

Configuration loads when the daemon starts. Restart the service after editing:

```sh
/Applications/Defi.app/Contents/MacOS/defi service restart
```

## CLI

The installed alpha CLI lives at `/Applications/Defi.app/Contents/MacOS/defi`.
Examples:

```sh
/Applications/Defi.app/Contents/MacOS/defi status
/Applications/Defi.app/Contents/MacOS/defi trace
/Applications/Defi.app/Contents/MacOS/defi focus-column left
/Applications/Defi.app/Contents/MacOS/defi workspace 2
/Applications/Defi.app/Contents/MacOS/defi move-window-to-workspace 3
/Applications/Defi.app/Contents/MacOS/defi quit
```

## Build from source

Local development build:

```sh
./script/build_and_run.sh
```

This builds, signs, and installs `~/Applications/Defi.app`. When no config
exists, it installs `defi.example.toml` as the initial user config.

The script uses an Apple Development identity. If multiple identities exist,
copy `.env.example` to the ignored `.env.local` and select the development
team, or set `DEFI_CODESIGN_IDENTITY` directly.

Create a local DMG without installing or launching Defi:

```sh
./script/package_dmg.sh
```

The artifact is written to `dist/`.

## Development checks

```sh
swift build
swift test --skip DesktopE2ETests
./script/test_desktop.sh
```

CI runs deterministic tests. Desktop tests are intentionally explicit: they
need an interactive Mac, real application windows, and Accessibility
permission. `./script/test_desktop.sh` stops the installed service, exercises
the desktop, restores changed windows, and restarts the service.

See [CONTRIBUTING.md](CONTRIBUTING.md) for code boundaries and contribution
guidance. See [ROADMAP.md](ROADMAP.md) for planned work.

## License

Defi is released under the [MIT License](LICENSE).
