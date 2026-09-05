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

After creating your first config file, quit and reopen Defi so it can watch
the config directory. Defi then reloads the file after each save. Invalid changes keep the last valid
configuration active and write an error to `~/Library/Logs/Defi.log` when using
the installed service. Reloading preserves workspace contents, focus, column
widths, and scroll positions. Geometry is recalculated only when a changed
setting affects the current layout.

Invalid TOML, values, workspace references, commands, accelerators, and modifier
aliases are shown in an app alert. Errors that prevent decoding stop startup;
invalid hotkeys disable keyboard capture for that run. Configured mouse focus
and cursor-motion tracking remain active when possible.

## `[layout]`

Controls column sizing, width cycling, focused-column placement, and gaps.

```toml
[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
center_focused_column = "never"
gaps = 8
outer_top_gap = 8
outer_right_gap = 8
outer_bottom_gap = 8
outer_left_gap = 8
reserved_top = 0
reserved_bottom = 0
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `default_column_width` | `0.80` | number from `0.05` to `1.0` | Fraction of monitor width assigned to each new column. |
| `preset_column_widths` | `[0.33, 0.50, 0.66, 0.80]` | non-empty array of numbers from `0.05` to `1.0` | Ordered widths used by `cycle-width`. Cycling wraps at both ends. |
| `center_focused_column` | `"never"` | `"never"` or `"always"` | `"always"` centers focused columns. `"never"` scrolls only enough to keep focus visible. |
| `gaps` | `8` | number from `0` to `256` | Uniform logical-pixel gap between windows and monitor edges. |
| `outer_top_gap` | `gaps` | number from `0` to `256` | Optional top-edge override. |
| `outer_right_gap` | `gaps` | number from `0` to `256` | Optional right-edge override. |
| `outer_bottom_gap` | `gaps` | number from `0` to `256` | Optional bottom-edge override. With an outside border, Defi still reserves the border width above the Dock. |
| `outer_left_gap` | `gaps` | number from `0` to `256` | Optional left-edge override. |
| `reserved_top` | `0` | number from `0` to `512` | Additional top inset after the macOS visible frame, for bars extending below the native menu-bar exclusion. |
| `reserved_bottom` | `0` | number from `0` to `512` | Additional bottom inset after the macOS visible frame. |

Widths are monitor-relative fractions. Existing pixel widths learned from
manual resize remain pixel-based and scale when monitor geometry changes.

Reserved values are extra insets, not raw bar dimensions. See
[SKETCHYBAR.md](SKETCHYBAR.md) for overlap calculation and live commands.

## `[menu_bar]`

Controls Defi's native macOS status item.

```toml
[menu_bar]
enabled = true
```

Set `enabled = false` when SketchyBar owns workspace presentation.

## `[input]`

Controls focus transfer between managed windows and pointer.

```toml
[input]
focus_follows_mouse = false
focus_follows_mouse_max_scroll_amount = 0.0
mouse_follows_focus = false
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `focus_follows_mouse` | `false` | boolean | Focuses managed window under physical pointer and scrolls strip minimally when needed. |
| `focus_follows_mouse_max_scroll_amount` | `0` | number from `0` to `1` | Maximum scroll as fraction of monitor width. `0` accepts only targets needing no scroll; `0.1` permits up to 10%. |
| `mouse_follows_focus` | `false` | boolean | Warps pointer to focused window center after keyboard focus changes, unless pointer is already inside it. |

Bare `focus_follows_mouse = true` does not scroll.
Raise `focus_follows_mouse_max_scroll_amount` to allow bounded scrolling. Both
options can run together. Pointer-driven focus never triggers cursor warp.
Programmatic cursor warp uses a CoreGraphics API that emits no mouse-moved
event. Defi also discards delayed warp when physical pointer moved after
initiating keyboard command. These boundaries prevent feedback loops and stale
cursor movement. CLI commands and native app focus changes never warp pointer.

## `[animation]`

Controls scrolling-column focus and managed column-resize animation.
The macOS Reduce Motion preference also disables these animations, including
workspace transitions and mouse-driven reordering.

```toml
[animation]
enabled = true
duration_ms = 35
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Enables visual scrolling and managed resize animation. |
| `duration_ms` | `35` | integer from `0` to `2000` | Animation duration in milliseconds. Vertical workspace transitions use at least 180 ms when the usable viewport covers the physical display; otherwise they switch immediately to prevent reserved-area leaks. `0` disables animation even when `enabled = true`. |

## `[overview]`

Controls the Overview scale and optional pixels inside window cards.

```toml
[overview]
zoom = 0.5
window_previews = false
window_corner_radius = 12
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `zoom` | `0.5` | number from `0` to `0.75` | Scales workspaces and windows. Lower values show more of the neighboring workspaces. |
| `window_previews` | `false` | boolean | Captures a card-sized still image when a window first becomes visible in the current Overview session. |
| `window_corner_radius` | `12` | number from `0` to `64` | Rounds window cards and their borders in the Overview. |

With the default `false`, Defi performs no Screen Recording permission check,
request, or ScreenCaptureKit content query. With `true`, the next Overview
opening reuses a valid in-memory preview when available, then captures a fresh
image. Denial, revocation, protected content, and capture errors leave the
icon-and-title cards fully usable and do not trigger repeated prompts in the
same daemon session.

Previews are memory-only, contain no audio or cursor, and use at most 32 MiB
between Overview sessions. Defi validates the window and process identity before
reuse, requests a fresh image immediately, and removes the remembered image if
that capture fails. Remembered previews are limited to 512 pixels on their longest
edge and retained until macOS signals memory pressure or their window identity
changes. Full-resolution previews are released on close. Closed Overview panels
and their desktop images are released after 60 seconds or under memory pressure. A full-display
screen share can include the Overview and the
content shown in its cards; sharing one selected application or window does not
normally include Defi's overlay.

When dragging a tiled card, the outer quarter on either side of a column creates
a neighboring column. Its central half inserts the card into the stack according
to pointer height. The Overview animates the projected ribbons immediately;
native windows receive only the final layout while the overlay is visible.

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
placement = "outside"
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Draws borders around visible tiled windows. |
| `width` | `4` | number from `0` to `64` | Border width in logical pixels. |
| `color` | `"#FFC099FF"` | `0xAARRGGBB` or `#AARRGGBB` string | Focused-window border color. |
| `inactive_enabled` | `false` | boolean | Draws borders around other visible tiled windows. |
| `inactive_color` | `"#66C099FF"` | `0xAARRGGBB` or `#AARRGGBB` string | Inactive-window border color. |
| `capture_enabled` | `false` | boolean | Makes border surfaces visible to screenshots and screen capture for debugging. |
| `placement` | `"outside"` | `"inside"` or `"outside"` | Draws the stroke inside the window edge (overlapping the first pixels of content) or just past it. |

With `placement = "outside"`, the stroke extends into the gaps. Defi reserves
one border width at monitor edges and between columns. These insets are
deducted from each column slot, so two 50% columns fit with their borders
without scrolling when focus changes.

Colors require exactly eight hexadecimal digits. First byte is alpha, followed
by red, green, and blue. Both prefixes accept uppercase or lowercase digits.

Borders never appear around parked, inactive-workspace, or floating windows.
Defi uses native WindowServer bounds and corner radii when available, with
Accessibility-frame and stable-radius fallbacks. Border surfaces ignore input.
With `capture_enabled = false`, they use `NSWindowSharingNone` and require no
Screen Recording permission.

## Mouse reordering

Drag a tiled window by its native title bar. Crossing a neighboring slot reorders
the column live and animates the other columns while the dragged window stays
under the pointer. Vertical dragging reorders windows inside the same stacked
column. Resizing remains width learning and never changes order. Reordering stays
inside the window's current monitor and active workspace. Mouse-down on an
adjacent column defers scroll alignment until release, so the strip stays fixed
under the pointer while deciding between a click and a drag.

## `[workspaces]`

Declares optional persistent named workspaces. Ordinary workspaces are dynamic.

```toml
[workspaces]
names = ["dev", "web", "tools"]
default = "dev"
monitors = { tools = 2 }
```

| Setting | Default | Values/type | Description |
| --- | --- | --- | --- |
| `names` | `[]` | array of unique strings | Persistent globally unique workspace names used by rules and stable bindings. |
| `default` | first entry in `names`, otherwise unset | string present in `names` | Startup workspace on its owning monitor. |
| `monitors` | `{}` | table from workspace name to 1-based display index | Initial monitor affinity for named workspaces; unspecified names use the primary display. |

Each workspace belongs to exactly one monitor. Every monitor keeps one trailing
empty workspace shown as `+`. Populating it turns it into an ordinary workspace
and creates another trailing workspace; an empty ordinary workspace disappears
after it becomes inactive. Named workspaces persist even when empty.

Workspace identity, ownership, order, focus, widths, and scroll position persist
across daemon restarts in the current macOS login session. If a display
disconnects, its workspaces move temporarily to a fallback display and return
when the same display identity reconnects. An explicit workspace-to-monitor move
updates its affinity.

Use stable, whitespace-free names. Workspace command arguments are separated by
whitespace, so names containing spaces cannot be addressed by keybindings or the
CLI. The `__defi_dynamic_` prefix is reserved for ordinary workspace identity.

Generated number shortcuts bind configured names first, then dynamic positions.
Example:

```toml
[workspaces]
names = ["dev", "web", "tools"]
```

This generates stable `alt-1 = "workspace dev"`, `alt-2 = "workspace web"`,
and `alt-3 = "workspace tools"` bindings. `alt-4` through `alt-9` address the
current monitor's dynamic positions. Matching `alt-shift-N` bindings use
`move-column-to-workspace-name` and follow the moved column. Positions are
1-based, do not wrap, and values beyond the current stack select trailing.

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

## `show_cheatsheet_on_modifier_hold`

Defaults to `true`. Hold `default_key_modifier` alone for 600 ms to show the
configured shortcuts on the active monitor without changing focus. Releasing the
modifier closes the help. Pressing another key before the delay cancels it.

Set this root-level option to `false` to disable hold-to-show. The
`toggle-cheatsheet` action remains available independently, so both triggers can
be used together:

```toml
show_cheatsheet_on_modifier_hold = false

[keys]
"alt-slash" = "toggle-cheatsheet"
```

There is no default binding for `toggle-cheatsheet`. It keeps the help open after
modifier release. Toggle again, press Escape, click, or execute any Defi shortcut
to close it. After a shortcut, release the modifiers before holding again.
Configuration reload and display or session changes also dismiss the help.
The cheatsheet displays the `hyper` modifier alias as `✦`. Other aliases expand
to their modifier symbols. Its fade respects `[animation].enabled` and Reduce Motion.

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

Commands use the same strings as the `defi` CLI. Named targets must be declared
in `[workspaces].names`; application rules cannot target dynamic positions.

| Command | Description | Generated default |
| --- | --- | --- |
| `focus-column left` | Focus previous column. | `<mod>-left` |
| `focus-column right` | Focus next column. | `<mod>-right` |
| `focus-column first` | Focus first column. | `<mod>-leftbracket` |
| `focus-column last` | Focus last column. | `<mod>-rightbracket` |
| `focus-workspace up\|down` | Focus the adjacent workspace without wrapping. | `<mod>-up` / `<mod>-down` |
| `focus-workspace-position <n>` | Focus a 1-based position, clamped to trailing. | `<mod>-1` … `<mod>-9` after configured names |
| `focus-workspace-name <name>` or `workspace <name>` | Focus a persistent named workspace, including on another monitor. | `<mod>-1` … `<mod>-9` for configured names |
| `focus-window up` | Focus previous window in current stack. | `<mod>-k` |
| `focus-window down` | Focus next window in current stack. | `<mod>-j` |
| `focus-window first` | Focus first window in current stack. | unset |
| `focus-window last` | Focus last window in current stack. | unset |
| `move-column left` | Move focused column left. | `<mod>-shift-left` |
| `move-column right` | Move focused column right. | `<mod>-shift-right` |
| `move-column first` | Move focused column to first position. | `<mod>-shift-leftbracket` |
| `move-column last` | Move focused column to last position. | `<mod>-shift-rightbracket` |
| `move-window up` | Move focused window up inside current stack. | `<mod>-shift-k` |
| `move-window down` | Move focused window down inside current stack. | `<mod>-shift-j` |
| `move-column-to-workspace up\|down\|<name>` | Move the focused column and follow it. Use `move-column-to-workspace-name <name>` when a name is `up` or `down`. | `<mod>-shift-up` / `<mod>-shift-down` |
| `send-column-to-workspace up\|down\|<name>` | Move the focused column without following it. | unset |
| `move-column-to-workspace-position <n>` | Move the focused column to a position and follow it. | `<mod>-shift-1` … `<mod>-shift-9` after configured names |
| `move-window-to-workspace up\|down\|<name>` | Move only the focused window and follow it. The explicit-name form is `move-window-to-workspace-name <name>`. | unset |
| `send-window-to-workspace up\|down\|<name>` | Move only the focused window without following it. | unset |
| `move-window-to-workspace-position <n>` | Move only the focused window to a position and follow it. | unset |
| `send-window-to-workspace-position <n>` | Move only the focused window to a position without following it. | unset |
| `focus-monitor left\|right\|up\|down` | Focus the nearest monitor in that direction. | `ctrl-cmd-<arrow>` |
| `move-column-to-monitor left\|right\|up\|down` | Move focused column to the nearest monitor. | `ctrl-cmd-shift-<arrow>` |
| `move-window-to-monitor left\|right\|up\|down` | Move only the focused window to the nearest monitor in that direction. | unset |
| `reorder-workspace up\|down` | Reorder the active workspace inside its monitor stack. | unset |
| `move-workspace-to-monitor left\|right\|up\|down` | Move the active workspace and update its monitor affinity. | unset |
| `cycle-width previous` | Select previous width preset, wrapping. | `<mod>-minus` |
| `cycle-width next` | Select next width preset, wrapping. | `<mod>-equal` |
| `maximize-column` | Toggle focused column between full width and previous width. | `<mod>-f` |
| `toggle-floating` | Toggle focused window between tiled and floating layers. | `<mod>-backslash` |
| `activate-floating` | Select floating layer and foreground its selected window. | `<mod>-shift-backslash` |
| `focus-floating previous` | Focus previous floating window, wrapping. | `<mod>-comma` |
| `focus-floating next` | Focus next floating window, wrapping. | `<mod>-period` |
| `focus-floating first` | Focus first floating window. | unset |
| `focus-floating last` | Focus last floating window. | unset |
| `join-window left` | Join focused window into stack on left. | `<mod>-semicolon` |
| `join-window right` | Join focused window into stack on right. | `<mod>-quote` |
| `unjoin-windows` | Split focused window from stack into new column. | `<mod>-r` |
| `toggle-cheatsheet` | Open or close keyboard shortcut help. | Unbound |
| `toggle-overview` | Open or close the interactive workspace Overview. | `<mod>-o` |
| `diagnostic-mark` | Record current status and recent trace without changing managed windows. | unset |

`previous` may be written as `prev`. `focus-column` also accepts
`previous`/`next`; `focus-window` accepts `previous`/`next`; `focus-floating`
accepts `left`/`right` and `up`/`down` as previous/next aliases.

Commands are validated when config loads. Direction compatibility can still be
validated at execution for commands implemented by the layout engine; use forms
listed above for deterministic behavior.

### Diagnostics

Defi keeps compact command summaries and high-signal anomalies in three rotating
10 MiB JSONL files under `~/Library/Logs/Defi/Diagnostics`. The files never
contain window titles, document contents, or typed text.

Bind `diagnostic-mark` when investigating an intermittent issue. It records the
current status and the recent in-memory trace without changing focus, layout,
frames, or visibility:

```toml
[keys]
"hyper-d" = "diagnostic-mark"
```

CLI-only integration commands:

| Command | Description |
| --- | --- |
| `list-workspaces` | Print current workspace labels per display. |
| `list-workspaces --json` | Print versioned per-display identity, position, name, kind, and application state. |
| `--monitor <index> <command>` | Execute command on 1-based `NSScreen.screens`/SketchyBar display index. |
| `set-reserved-area top\|bottom <points>` | Override extra reserved edge on every display, or targeted `--monitor`. |
| `clear-reserved-area` | Restore configured reserved edges. |

See [SKETCHYBAR.md](SKETCHYBAR.md) for event contract and example scripts.

### Native macOS fullscreen

`maximize-column` changes only Defi's logical column width. It does not enter
native macOS fullscreen or create a macOS Space.

Native fullscreen lifecycle support follows this policy:

- macOS or the application owns fullscreen entry and exit; Defi passes those
  actions through and never substitutes `maximize-column`
- while macOS reports a window in native fullscreen, Defi temporarily removes
  it from the visible strip and performs no layout, parking, frame, border, or
  automatic focus writes for that window
- Defi preserves the window's logical column slot, width, monitor, workspace,
  and focus selection; explicit Defi focus commands may still select it
- on exit, Defi restores the window to that slot and reconciles once against
  current monitor topology; normal deterministic monitor fallback applies when
  the original monitor no longer exists
- stale fullscreen events cannot restore older layout, visibility, or focus
  state; latest transition wins

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
| `follow_focus` | `false` | boolean | Activates the target workspace when the newly discovered matching window has native focus. |
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

Rules apply when a window is first discovered. Reloaded rules affect windows
discovered afterward without moving windows already managed by Defi.

## Built-in defaults

These values are active without config. Normal config should contain overrides
only.

```toml
default_key_modifier = "alt"
show_cheatsheet_on_modifier_hold = true

[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
center_focused_column = "never"
gaps = 8
reserved_top = 0
reserved_bottom = 0

[menu_bar]
enabled = true

[animation]
enabled = true
duration_ms = 35

[overview]
zoom = 0.5
window_previews = false
window_corner_radius = 12

[decorations.borders]
enabled = true
width = 4
color = "#FFC099FF"
inactive_enabled = false
inactive_color = "#66C099FF"
capture_enabled = false
placement = "outside"

[workspaces]
names = []

[modifier_combinations]

[keys]
"alt-left" = "focus-column left"
"alt-right" = "focus-column right"
"alt-j" = "focus-window down"
"alt-k" = "focus-window up"
"alt-up" = "focus-workspace up"
"alt-down" = "focus-workspace down"
"alt-o" = "toggle-overview"
"alt-leftbracket" = "focus-column first"
"alt-rightbracket" = "focus-column last"

"alt-shift-left" = "move-column left"
"alt-shift-right" = "move-column right"
"alt-shift-j" = "move-window down"
"alt-shift-k" = "move-window up"
"alt-shift-up" = "move-column-to-workspace up"
"alt-shift-down" = "move-column-to-workspace down"
"alt-shift-leftbracket" = "move-column first"
"alt-shift-rightbracket" = "move-column last"

"alt-1" = "focus-workspace-position 1"
# ... through alt-9
"alt-shift-1" = "move-column-to-workspace-position 1"
# ... through alt-shift-9

"ctrl-cmd-left" = "focus-monitor left"
"ctrl-cmd-right" = "focus-monitor right"
"ctrl-cmd-up" = "focus-monitor up"
"ctrl-cmd-down" = "focus-monitor down"
"ctrl-cmd-shift-left" = "move-column-to-monitor left"
"ctrl-cmd-shift-right" = "move-column-to-monitor right"
"ctrl-cmd-shift-up" = "move-column-to-monitor up"
"ctrl-cmd-shift-down" = "move-column-to-monitor down"

"alt-minus" = "cycle-width previous"
"alt-equal" = "cycle-width next"
"alt-f" = "maximize-column"
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

Startup commands, dimming, per-edge gaps, and removing generated keybindings are
not implemented. No compatibility aliases exist before
the first stable release; use setting names exactly as documented.

## Full example

See [config.example.toml](config.example.toml) for a daily-use config with named
workspaces, a Hyper modifier, and application rules.
