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

## `[experimental]`

```toml
[experimental]
skylight_position_animation = false
```

- `skylight_position_animation`: use private SkyLight compositor transforms for visible
  horizontal animation frames. Disabled by default. Resize, focus, parking, and
  non-animated frame commits remain on Accessibility. A delayed Accessibility
  settlement synchronizes app-owned geometry after visual completion. Missing
  symbols or repeated failures automatically fall back to Accessibility for the
  session. This experiment does not request Screen Recording permission.

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
- `floating`: leave unmanaged
- `force_tiling`: manage windows normally filtered by role/subrole
- `intrinsic_size`: preserve observed window size inside column

Matching rules combine. Later workspace wins. Boolean flags OR together.

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
- `alt-semicolon/quote`: join left/right
- `alt-r`: unjoin

## Unsupported in basic MVP

Borders, dimming, status item, startup commands, config hot reload, and floating-window management remain roadmap items.
