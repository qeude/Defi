# Configuration

Defi works without config. Defaults provide nine workspaces and keyboard bindings.

Default path: `~/.config/defi/config.toml`. Override by launching bundled daemon with `--config <path>`.

## `[layout]`

```toml
[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
center_focused_column = "never"
gaps = 8
```

- `default_column_width`: new-column fraction, `0.05...1.0`
- `preset_column_widths`: non-empty width fractions
- `center_focused_column`: `never` or `always`
- `gaps`: uniform logical-pixel gap, `0...256`

## `[animation]`

```toml
[animation]
enabled = true
duration_ms = 35
```

- `enabled`: animate scrolling-column focus and managed column resize commands
- `duration_ms`: animation duration, `0...2000`; `0` disables animation

## `[decorations.borders]`

```toml
[decorations.borders]
enabled = true
width = 4
color = "#FFC099FF"
inactive_enabled = false
inactive_color = "#66C099FF"
capture_enabled = false
```

- `enabled`: draw window borders; default `true`
- `width`: logical-pixel border width, `0...64`; default `4`
- `color`: selected-window color in `0xAARRGGBB` or `#AARRGGBB` form
- `inactive_enabled`: draw borders around other visible tiled windows; default `false`
- `inactive_color`: inactive-window color in same ARGB format
- `capture_enabled`: include border overlays in screenshots and screen capture for
  debugging; default `false`

Each visible managed window owns a stable lightweight border node backed by four
narrow edge surfaces instead of one full-window surface. In active-only mode,
only the active border remains ordered; dormant surfaces are ordered out and
compacted to one pixel. Enabling inactive borders keeps four
narrow surfaces per visible tiled window, never parked or off-workspace windows.
Unchanged decoration plans perform no AppKit work.

Borders automatically read native WindowServer bounds and corner radii when the
dynamically resolved symbols are available. Bounds fall back to observed
Accessibility frames; corner radii fall back to the stable macOS radius. No
configuration switch is required. Native move and resize notifications refresh
visible border geometry immediately.
Every mouse-drag event also refreshes visible borders directly, while the bounded
refresh tick rises to the active display rate during the gesture. This keeps the
active border on the real displayed size even when an application coalesces
Accessibility notifications.
New surfaces are placed and ordered while transparent. They become opaque
immediately after the target receives native focus. Borders disappear and change
color immediately, avoiding stale presentation opacity and compositor timing.
Strokes stay inside the exact target frame. Surfaces ignore all input. They
use `NSWindowSharingNone` by default, so they stay outside screenshots and never
request Screen Recording permission. Z-order and capture sharing are independent.
`capture_enabled = true` changes sharing to read-only for debugging; restart Defi
after changing it. App-scoped capture tools such as Computer Use expose the Defi
edge surfaces individually; full-desktop capture shows the composed border.

## Mouse reordering

Drag a tiled window by its native title bar. Crossing a neighboring slot reorders
the column live and animates the other columns while the dragged window stays
under the pointer. Vertical dragging reorders windows inside the same stacked
column. Resizing remains width learning and never changes order. Reordering stays
inside the window's current monitor and active workspace. Mouse-down on an
adjacent column defers scroll alignment until release, so the strip stays fixed
under the pointer while deciding between a click and a drag.

## `[workspaces]`

```toml
[workspaces]
names = ["dev", "web", "tools"]
default = "dev"
```

Defaults: names `1` through `9`; default `1`.

Every connected monitor owns an independent copy of this workspace set.
Switching workspace `5` on one monitor does not switch another monitor.
Layouts always use each monitor's own visible frame and are recomputed after
display connection, disconnection, or geometry changes.

## `default_key_modifier`

Controls generated default bindings. Value may be a modifier or alias.

```toml
default_key_modifier = "hyper"

[modifier_combinations]
hyper = "Alt + Cmd + Ctrl"
```

Default modifier: `alt`.

## `[keys]`

```toml
[keys]
"hyper-left" = "focus-column left"
"hyper-right" = "focus-column right"
"hyper-shift-1" = "move-window-to-workspace dev"
```

Supported commands:

- `focus-column left|right|first|last`
- `focus-window up|down|first|last`
- `move-column left|right|first|last`
- `move-window up|down`
- `workspace <name>`
- `move-window-to-workspace <name>`
- `send-window-to-workspace <name>`
- `cycle-width previous|next`
- `toggle-fullscreen`
- `toggle-floating`
- `activate-floating`
- `focus-floating previous|next|first|last`
- `join-window left|right`
- `unjoin-windows`

## `[[rules]]`

```toml
[[rules]]
app_id = "com.apple.iphonesimulator"
workspace = "dev"
follow_focus = true
force_tiling = true
intrinsic_size = true
```

- `app_id`: case-insensitive bundle ID or app-name match
- `title`: case-insensitive title substring
- `role`: exact AX role
- `workspace`: target workspace name
- `follow_focus`: switch to target on discovery
- `floating`: keep in workspace floating layer
- `force_tiling`: manage windows normally filtered by role/subrole
- `intrinsic_size`: preserve observed window size inside column

Matching rules combine. Later workspace wins. Boolean flags OR together.

Defi automatically treats auxiliary and fixed-size macOS windows as floating:
sheets, dialogs, system dialogs, native floating panels, and standard windows
without resize or close controls. This covers common delete confirmations, copy
progress, installers, and app update windows when their Accessibility metadata
identifies them as auxiliary. `force_tiling = true` overrides this classification.

Floating windows keep their observed size and position. They park with their
workspace, restore on activation, and remain isolated per monitor.

## Built-in bindings

With default modifier `alt`:

- `alt-left/right`: focus column
- `alt-up/down`: focus window inside stack
- `alt-shift-left/right`: move column
- `alt-shift-up/down`: move window inside stack
- `alt-1...9`: switch workspace
- `alt-shift-1...9`: move focused window and follow
- `alt-minus/equal`: cycle width
- `alt-f`: fullscreen column
- `alt-backslash`: toggle focused window tiled/floating
- `alt-shift-backslash`: activate floating layer and foreground selected window
- `alt-comma/period`: cycle floating windows backward/forward
- `alt-semicolon/quote`: join left/right
- `alt-r`: unjoin

## Unsupported in basic MVP

Dimming, startup commands, and config hot reload remain roadmap items.
