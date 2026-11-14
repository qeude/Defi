# SketchyBar integration

Show Defi's workspaces in [SketchyBar](https://github.com/FelixKratz/SketchyBar),
one item per workspace and display. Defi pushes every change to SketchyBar, so
nothing polls. Clicking an item switches that display to the workspace.

## Install

You need `jq`. From the Defi repository root:

```sh
mkdir -p ~/.config/sketchybar/plugins
cp contrib/sketchybar/plugins/defi_*.sh ~/.config/sketchybar/plugins/
chmod +x ~/.config/sketchybar/plugins/defi_workspace*.sh
cp contrib/sketchybar/defi.sh ~/.config/sketchybar/defi.sh
chmod +x ~/.config/sketchybar/defi.sh
```

Then source it near the end of `~/.config/sketchybar/sketchybarrc` and reload
SketchyBar:

```sh
source "$CONFIG_DIR/defi.sh"
```

The scripts look for Defi in `~/Applications`, then `/Applications`, then your
`PATH`. If Defi lives elsewhere, set `DEFI_BIN` in SketchyBar's service
environment.

A hidden observer adds and removes items as workspaces come and go, including
when displays connect or disconnect.

To hide Defi's own menu bar item, add this to your Defi config:

```toml
[menu_bar]
enabled = false
```

## Keep windows clear of the bar

Defi already avoids the macOS menu bar and the Dock. If your bar reaches below
the menu bar, reserve only the part that sticks out:

```toml
[layout]
reserved_top = 8
reserved_bottom = 0
```

To find the right value, try it live. These commands accept 0 to 512 points and
apply to every display unless you pass `--monitor`:

```sh
defi set-reserved-area top 8
defi --monitor 2 set-reserved-area top 12
defi clear-reserved-area          # back to the configured values
```

Compute the overlap from SketchyBar's `height`, `notch_display_height`,
`margin`, `y_offset`, `position`, and `hidden` rather than copying the bar
height. A bar that fits inside the menu bar needs no reservation.

## State for your own scripts

Read the current state at any time:

```sh
defi list-workspaces --json
```

The versioned JSON contains:

- the focused monitor ID
- each display's AppKit/SketchyBar index and active workspace
- each workspace's stable ID, 1-based position, optional name, and kind
  (`named`, `ordinary`, or `trailing`)
- each workspace's window count, occupied state, and the bundle IDs on it
- the focused app and selected window of each active workspace
- each workspace's windows: ID, bundle ID, 1-based column and row (absent for
  floating windows), and whether each is floating or selected

Without `--json`, `defi list-workspaces` prints the labels per display.

On every change, Defi posts the same object as the distributed notification
`com.qeude.defi.workspaceChanged`, which SketchyBar receives as the
`defi_workspace_change` event with the JSON in `$INFO`. Tools that keep a
connection open can use `defi subscribe --json` instead: it carries the same
object in its `snapshot`, `workspaces-changed`, and `monitors-changed` events,
plus focus and window events with window titles. See
[Event stream](../../CONFIGURATION.md#event-stream).
