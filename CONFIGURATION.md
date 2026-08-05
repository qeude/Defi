# Configuration

Defi works without a config file. Add one only for user-specific workspace
names, keybindings, application rules, or explicit layout and visual overrides.

## Config file

Defi reads `~/.config/defi/config.toml` by default. A missing file uses every
built-in default documented below.

Launch the daemon with another file when needed:

```sh
~/Applications/Defi.app/Contents/MacOS/defi-daemon --config /path/to/config.toml
```

Config loads once when the daemon starts. Restart the installed service after
editing the default file:

```sh
~/Applications/Defi.app/Contents/MacOS/defi service restart
```

Invalid TOML, invalid values, unknown workspaces in rules or commands, and
invalid command strings stop config loading. An invalid accelerator or modifier
alias disables hotkeys for that daemon run and writes an error to
`~/Library/Logs/Defi.log` when using the installed service.

## `[layout]`

Controls column sizing, width cycling, focused-column placement, and gaps.

```toml
[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
center_focused_column = "never"
gaps = 8
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `default_column_width` | `0.80` | number from `0.05` to `1.0` | Fraction of monitor width assigned to each new column. |
| `preset_column_widths` | `[0.33, 0.50, 0.66, 0.80]` | non-empty array of numbers from `0.05` to `1.0` | Ordered widths used by `cycle-width`. Cycling wraps at both ends. |
| `center_focused_column` | `"never"` | `"never"` or `"always"` | `"always"` centers focused columns. `"never"` scrolls only enough to keep focus visible. |
| `gaps` | `8` | number from `0` to `256` | Uniform logical-pixel gap between windows and monitor edges. |

Widths are monitor-relative fractions. Existing pixel widths learned from
manual resize remain pixel-based and scale when monitor geometry changes.

## `[animation]`

Controls scrolling-column focus and managed column-resize animation.

```toml
[animation]
enabled = true
duration_ms = 35
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Enables visual scrolling and managed resize animation. |
| `duration_ms` | `35` | integer from `0` to `2000` | Animation duration in milliseconds. `0` disables animation even when `enabled = true`. |

## `[decorations.borders]`

Controls borders around visible tiled windows.

```toml
[decorations.borders]
enabled = true
width = 4
color = "#FFC099FF"
inactive_enabled = false
inactive_color = "#66C099FF"
capture_enabled = false
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Draws borders around visible tiled windows. |
| `width` | `4` | number from `0` to `64` | Border width in logical pixels. |
| `color` | `"#FFC099FF"` | `0xAARRGGBB` or `#AARRGGBB` string | Focused-window border color. |
| `inactive_enabled` | `false` | boolean | Draws borders around other visible tiled windows. |
| `inactive_color` | `"#66C099FF"` | `0xAARRGGBB` or `#AARRGGBB` string | Inactive-window border color. |
| `capture_enabled` | `false` | boolean | Makes border surfaces visible to screenshots and screen capture for debugging. |

Colors require exactly eight hexadecimal digits. First byte is alpha, followed
by red, green, and blue. Both prefixes accept uppercase or lowercase digits.

Borders never appear around parked, inactive-workspace, or floating windows.
Defi uses native WindowServer bounds and corner radii when available, with
Accessibility-frame and stable-radius fallbacks. Border surfaces ignore input.
With `capture_enabled = false`, they use `NSWindowSharingNone` and require no
Screen Recording permission.

## `[workspaces]`

Defines stable workspace IDs and startup workspace.

```toml
[workspaces]
names = ["dev", "web", "tools"]
default = "dev"
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `names` | `["1", "2", "3", "4", "5", "6", "7", "8", "9"]` | non-empty array of unique strings | Workspace IDs used by commands, keybindings, and rules. |
| `default` | first entry in `names` (`"1"` by default) | string present in `names` | Workspace active on each monitor at daemon startup. |

Every connected monitor owns an independent copy of this workspace set. Each
monitor preserves its own active workspace, focus, widths, and scroll offset.

Use stable, whitespace-free names. Workspace command arguments are separated by
whitespace, so names containing spaces cannot be addressed by keybindings or the
CLI.

Generated number shortcuts target the first nine entries by position. Example:

```toml
[workspaces]
names = ["dev", "web", "tools"]
```

This generates `alt-1 = "workspace dev"`, `alt-2 = "workspace web"`, and
`alt-3 = "workspace tools"`, plus matching `alt-shift-N` move bindings.

## `default_key_modifier`

Controls the modifier prefix used to generate built-in bindings.

```toml
default_key_modifier = "hyper"

[modifier_combinations]
hyper = "Alt + Cmd + Ctrl"
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `default_key_modifier` | `"alt"` | modifier name, hyphen-separated modifiers, or alias | Prefix used for every generated default binding. |

Changing this value moves all generated navigation, layout, floating-window,
stacking, and first-nine-workspace bindings to the new prefix.

## `[modifier_combinations]`

Defines reusable modifier aliases for accelerators.

```toml
[modifier_combinations]
hyper = "Alt + Cmd + Ctrl"
meh = "Alt + Ctrl + Shift"
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| any lowercase alias | none | `+`-separated modifier string | Alias available as one accelerator component and as `default_key_modifier`. |

Accepted modifier names are:

| Canonical name | Accepted names |
| --- | --- |
| Command | `cmd`, `command` |
| Option | `alt`, `option` |
| Control | `ctrl`, `control` |
| Shift | `shift` |

Names are case-insensitive inside alias values. Alias keys should be lowercase.
Aliases cannot reference other aliases.

## `[keys]`

Binds accelerators to Defi commands.

```toml
[keys]
"hyper-left" = "focus-column left"
"hyper-shift-1" = "move-window-to-workspace dev"
```

Custom entries merge with generated defaults. A matching accelerator overrides
its generated command; unrelated generated bindings remain active. Unbinding a
generated accelerator is not currently supported.

### Accelerator syntax

Format: `<modifier-or-alias>-<modifier>-<key>`. Order and letter case do not
matter. Final component must be a supported key name.

Supported key names:

- letters: `a` through `z`
- digits: `0` through `9`
- arrows: `left`, `right`, `up`, `down`
- punctuation: `minus`, `equal`, `leftbracket`, `rightbracket`, `semicolon`,
  `quote`, `backslash`, `comma`, `period`, `slash`

Examples: `alt-left`, `cmd-shift-p`, `hyper-backslash`.

### Commands

Commands use the same strings as the `defi` CLI. Workspace arguments must name
an entry from `[workspaces].names`.

| Command | Description | Generated default |
| --- | --- | --- |
| `focus-column left` | Focus previous column. | `<mod>-left` |
| `focus-column right` | Focus next column. | `<mod>-right` |
| `focus-column first` | Focus first column. | `<mod>-leftbracket` |
| `focus-column last` | Focus last column. | `<mod>-rightbracket` |
| `focus-window up` | Focus previous window in current stack. | `<mod>-up` |
| `focus-window down` | Focus next window in current stack. | `<mod>-down` |
| `focus-window first` | Focus first window in current stack. | unset |
| `focus-window last` | Focus last window in current stack. | unset |
| `move-column left` | Move focused column left. | `<mod>-shift-left` |
| `move-column right` | Move focused column right. | `<mod>-shift-right` |
| `move-column first` | Move focused column to first position. | `<mod>-shift-leftbracket` |
| `move-column last` | Move focused column to last position. | `<mod>-shift-rightbracket` |
| `move-window up` | Move focused window up inside current stack. | `<mod>-shift-up` |
| `move-window down` | Move focused window down inside current stack. | `<mod>-shift-down` |
| `workspace <name>` | Switch active monitor to workspace. | `<mod>-1` … `<mod>-9` |
| `move-window-to-workspace <name>` | Move focused window and follow it. | `<mod>-shift-1` … `<mod>-shift-9` |
| `send-window-to-workspace <name>` | Move focused window without switching workspace. | unset |
| `cycle-width previous` | Select previous width preset, wrapping. | `<mod>-minus` |
| `cycle-width next` | Select next width preset, wrapping. | `<mod>-equal` |
| `toggle-fullscreen` | Toggle focused column between full width and previous width. | `<mod>-f` |
| `toggle-floating` | Toggle focused window between tiled and floating layers. | `<mod>-backslash` |
| `activate-floating` | Select floating layer and foreground its selected window. | `<mod>-shift-backslash` |
| `focus-floating previous` | Focus previous floating window, wrapping. | `<mod>-comma` |
| `focus-floating next` | Focus next floating window, wrapping. | `<mod>-period` |
| `focus-floating first` | Focus first floating window. | unset |
| `focus-floating last` | Focus last floating window. | unset |
| `join-window left` | Join focused window into stack on left. | `<mod>-semicolon` |
| `join-window right` | Join focused window into stack on right. | `<mod>-quote` |
| `unjoin-windows` | Split focused window from stack into new column. | `<mod>-r` |

`previous` may be written as `prev`. `focus-column` also accepts
`previous`/`next`; `focus-window` accepts `previous`/`next`; `focus-floating`
accepts `left`/`right` and `up`/`down` as previous/next aliases.

Commands are validated when config loads. Direction compatibility can still be
validated at execution for commands implemented by the layout engine; use forms
listed above for deterministic behavior.

## `[[rules]]`

Application rules assign newly discovered windows to workspaces and override
normal floating or tiling classification. Add one table per rule.

```toml
[[rules]]
app_id = "com.apple.iphonesimulator"
title = "Simulator"
role = "AXWindow"
workspace = "dev"
follow_focus = true
floating = false
force_tiling = true
intrinsic_size = true
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `app_id` | unset | string | Case-insensitive bundle ID or application-name match. Exact matches and suffix matches in either direction pass. |
| `title` | unset | string | Case-insensitive substring match against window title. |
| `role` | unset | string | Exact, case-sensitive Accessibility role match, such as `AXWindow`. |
| `workspace` | unset | string present in `[workspaces].names` | Places newly discovered matching window on workspace. |
| `follow_focus` | `false` | boolean | Activates target workspace and selects matching window when discovered. |
| `floating` | `false` | boolean | Places matching window in workspace floating layer. |
| `force_tiling` | `false` | boolean | Tiles matching window even when platform classification would normally float or ignore it. Overrides `floating`. |
| `intrinsic_size` | `false` | boolean | Preserves observed window width and height inside its tile. |

At least one matcher (`app_id`, `title`, or `role`) must be set for a rule to
match. When multiple matchers exist in one rule, all must match.

Multiple matching rules combine in file order:

- last matching `workspace` wins
- boolean values combine with OR; later `false` cannot clear an earlier `true`

Defi automatically floats sheets, dialogs, system dialogs, native floating
panels, and standard windows identified as fixed-size or auxiliary. Floating
windows keep observed size and position, park with their workspace, and remain
isolated per monitor. Use `force_tiling = true` only for windows known to behave
correctly when resized.

Rules apply when a window is first discovered. Config hot reload is unsupported;
restart Defi after changing rules.

## Built-in defaults

These values are active without config. Normal config should contain overrides
only.

```toml
default_key_modifier = "alt"

[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
center_focused_column = "never"
gaps = 8

[animation]
enabled = true
duration_ms = 35

[decorations.borders]
enabled = true
width = 4
color = "#FFC099FF"
inactive_enabled = false
inactive_color = "#66C099FF"
capture_enabled = false

[workspaces]
names = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]
default = "1"

[modifier_combinations]

[keys]
"alt-left" = "focus-column left"
"alt-right" = "focus-column right"
"alt-up" = "focus-window up"
"alt-down" = "focus-window down"
"alt-leftbracket" = "focus-column first"
"alt-rightbracket" = "focus-column last"

"alt-shift-left" = "move-column left"
"alt-shift-right" = "move-column right"
"alt-shift-up" = "move-window up"
"alt-shift-down" = "move-window down"
"alt-shift-leftbracket" = "move-column first"
"alt-shift-rightbracket" = "move-column last"

"alt-1" = "workspace 1"
"alt-2" = "workspace 2"
"alt-3" = "workspace 3"
"alt-4" = "workspace 4"
"alt-5" = "workspace 5"
"alt-6" = "workspace 6"
"alt-7" = "workspace 7"
"alt-8" = "workspace 8"
"alt-9" = "workspace 9"

"alt-shift-1" = "move-window-to-workspace 1"
"alt-shift-2" = "move-window-to-workspace 2"
"alt-shift-3" = "move-window-to-workspace 3"
"alt-shift-4" = "move-window-to-workspace 4"
"alt-shift-5" = "move-window-to-workspace 5"
"alt-shift-6" = "move-window-to-workspace 6"
"alt-shift-7" = "move-window-to-workspace 7"
"alt-shift-8" = "move-window-to-workspace 8"
"alt-shift-9" = "move-window-to-workspace 9"

"alt-minus" = "cycle-width previous"
"alt-equal" = "cycle-width next"
"alt-f" = "toggle-fullscreen"
"alt-backslash" = "toggle-floating"
"alt-shift-backslash" = "activate-floating"
"alt-comma" = "focus-floating previous"
"alt-period" = "focus-floating next"
"alt-semicolon" = "join-window left"
"alt-quote" = "join-window right"
"alt-r" = "unjoin-windows"

# No rules by default.
```

## Unsupported configuration

Startup commands, dimming, per-edge gaps, removing generated keybindings, and
config hot reload are not implemented. No compatibility aliases exist before
the first stable release; use setting names exactly as documented.

## Full example

See [defi.example.toml](defi.example.toml) for a daily-use config with named
workspaces, a Hyper modifier, and application rules.
