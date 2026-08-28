# SketchyBar integration

Defi publishes workspace state through the distributed notification
`com.quentin.defi.workspaceChanged`. SketchyBar can consume it as the custom
event `defi_workspace_change`. No polling is needed after initial setup.

## Install the example

The example requires `jq`. Scripts find Defi in `~/Applications`, then
`/Applications`, then `PATH`.

```sh
mkdir -p ~/.config/sketchybar/plugins
cp contrib/sketchybar/plugins/defi_workspace*.sh ~/.config/sketchybar/plugins/
chmod +x ~/.config/sketchybar/plugins/defi_workspace*.sh
cp contrib/sketchybar/defi.sh ~/.config/sketchybar/defi.sh
chmod +x ~/.config/sketchybar/defi.sh
```

Source the integration near the end of `~/.config/sketchybar/sketchybarrc`:

```sh
source "$CONFIG_DIR/defi.sh"
```

Reload SketchyBar. The setup creates one item for every workspace currently
owned by each display. A hidden observer reconciles dynamic workspaces after display connection or
disconnection. Clicking an item targets that display, including when another
display currently owns focus.

Set `DEFI_BIN` in SketchyBar's service environment when Defi lives elsewhere.

## Reserved bar area

Defi starts with `NSScreen.visibleFrame`, which already excludes the macOS menu
bar and Dock. Reserve only the extra portion of SketchyBar that overlaps this
visible frame:

```toml
[layout]
reserved_top = 8
reserved_bottom = 0
```

Restart Defi after changing persistent configuration. Test values live without
restart:

```sh
defi set-reserved-area top 8
defi --monitor 2 set-reserved-area top 12
defi clear-reserved-area
```

Omitting `--monitor` applies a reserved-area command to every connected display.
`clear-reserved-area` restores configured values. Valid values range from 0 to
512 points.

SketchyBar exposes `height`, `notch_display_height`, `margin`, `y_offset`,
`position`, and `hidden`. Calculate overlap after those properties, rather than
copying raw bar height. A bar entirely inside the native menu-bar exclusion
needs no additional reservation.

## State contract

Bootstrap current state at any time:

```sh
defi list-workspaces --json
```

The versioned JSON contains:

- focused monitor ID;
- AppKit/SketchyBar display index;
- active workspace per display;
- stable workspace ID, 1-based position, optional name, and `named`, `ordinary`,
  or `trailing` kind;
- window count and occupied state;
- bundle identifiers present on every workspace;
- focused application per active workspace.

`defi list-workspaces` without `--json` prints current labels per display.
Distributed notifications contain the same JSON object in SketchyBar's `$INFO`
variable. Defi emits only when this state changes.

## Native Defi menu item

Disable Defi's native status item when SketchyBar replaces it:

```toml
[menu_bar]
enabled = false
```
