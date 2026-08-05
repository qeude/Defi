# Defi

[![CI](https://github.com/qeude/Defi/actions/workflows/ci.yml/badge.svg)](https://github.com/qeude/Defi/actions/workflows/ci.yml)

macOS-native scrolling-column window manager inspired by Niri.

Basic MVP includes:

- multiple visible scrolling columns
- independent virtual workspaces per monitor
- Accessibility window discovery, placement, and focus
- global configurable hotkeys
- TOML config and application rules
- Unix-socket CLI
- `launchd` development service commands
- native application/focus event synchronization
- real frame/target reconciliation and mouse-resize width learning
- topology-aware parking lanes with one-pixel side anchors
- delayed real-frame verification and automatic parking repair
- continuous scrolling strip with bounded neighboring-column prefetch
- 60 Hz pixel-aligned scrolling with coalesced, per-app AX frame batches
- selectable empty virtual workspaces
- menu bar workspace and action controls

No config required. Defaults provide workspaces `1...9` and Option-based bindings.

## Build and run

```sh
./script/build_and_run.sh
```

Script builds, signs, and installs stable bundle at:

```text
~/Applications/Defi.app
```

When absent, script installs `defi.example.toml` as `~/.config/defi/config.toml`.
That daily-use config enables `hyper = Alt + Cmd + Ctrl`, named workspaces, and app rules.

macOS requests Accessibility permission. Enable `Defi` under:

`System Settings → Privacy & Security → Accessibility`

Verify daemon:

```sh
./script/build_and_run.sh --verify
```

## CLI

```sh
~/Applications/Defi.app/Contents/MacOS/defi status
~/Applications/Defi.app/Contents/MacOS/defi trace
~/Applications/Defi.app/Contents/MacOS/defi focus-column left
~/Applications/Defi.app/Contents/MacOS/defi focus-column right
~/Applications/Defi.app/Contents/MacOS/defi workspace 2
~/Applications/Defi.app/Contents/MacOS/defi move-window-to-workspace 3
~/Applications/Defi.app/Contents/MacOS/defi quit
```

Default hotkeys:

- `Option + Left/Right`: focus column
- `Option + Up/Down`: focus stacked window
- `Option + Shift + arrows`: move column/window
- `Option + 1...9`: switch workspace
- `Option + Shift + 1...9`: move window and follow
- `Option + -/=`: cycle width
- `Option + F`: fullscreen column
- `Option + \\`: toggle focused window tiled/floating
- `Option + Shift + \\`: foreground selected floating window
- `Option + ,/.`: cycle floating windows

## Config

Default path: `~/.config/defi/config.toml`.

Start from [defi.example.toml](defi.example.toml) only when custom workspace names, aliases, or rules are needed. Full reference: [CONFIGURATION.md](CONFIGURATION.md).

Run with explicit config:

```sh
~/Applications/Defi.app/Contents/MacOS/defi-daemon --config ./defi.example.toml
```

## Development service

After `./script/build_and_run.sh`, signed binaries live inside stable app bundle:

```sh
~/Applications/Defi.app/Contents/MacOS/defi service install
~/Applications/Defi.app/Contents/MacOS/defi service start
~/Applications/Defi.app/Contents/MacOS/defi service status
~/Applications/Defi.app/Contents/MacOS/defi service restart
~/Applications/Defi.app/Contents/MacOS/defi service stop
```

Service points at stable installed app bundle.
Defi restores parked windows before managed shutdown or service stop.

## Signing identity

Local builds use the only available Apple Development identity. When multiple
identities are installed, copy `.env.example` to the ignored `.env.local` and
select the local developer team:

```sh
cp .env.example .env.local
# Edit .env.local: DEFI_DEVELOPMENT_TEAM=TEAMID
./script/build_and_run.sh
```

Environment variables override `.env.local`. Select an exact identity when a
team has multiple valid development certificates:

```sh
DEFI_CODESIGN_IDENTITY=SHA1 ./script/build_and_run.sh
```

Team selection matches the certificate's Apple team identifier, not the suffix
shown in its display name.

Stable bundle ID and signing identity preserve Accessibility permission across builds.

## Verify

```sh
swift build
swift test
./script/test_desktop.sh
```

Desktop tests temporarily stop the installed LaunchAgent, exercise native
focus, offscreen workspace parking, and real frame convergence, restore changed
windows, then restart the service.

`defi trace` prints the bounded AX frame-coordinator history. `submit` includes
the layout source; animation samples expose inter-app completion spread.
`quality` reports adaptive intermediate-frame reduction when AX is slow.
`commit-observed` reports real-frame settling and deferred post-animation
corrections without unbounded log growth.

Metal animation, borders, dimming, and config hot reload remain later phases.
