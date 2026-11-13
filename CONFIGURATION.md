# Configuration

Defi works without a config file. Add `~/.config/defi/config.toml` only for
what you want to change: workspace names, shortcuts, app rules, or layout and
visual tweaks. Every option and its default is listed below.

```toml
mod = "ctrl+alt+cmd"           # Hyper key as the shortcut modifier

[layout]
gaps = 12

[workspaces]
names = ["dev", "web"]         # ⌃⌥⌘1 and ⌃⌥⌘2 jump to them

[[rules]]
app_id = "com.apple.Safari"
workspace = "web"
```

The [example configuration](config.example.toml) is the maintainer's daily
setup, with named workspaces, a Hyper `mod`, and app rules.

**Contents**

- [Config file](#config-file)
- Layout: [`[layout]`](#layout) · [`[workspaces]`](#workspaces) · [`[[rules]]`](#rules)
- Keyboard: [`mod`](#mod) · [Cheatsheet](#show_cheatsheet_on_modifier_hold) ·
  [`[keys]`](#keys) · [Commands](#commands)
- Mouse and trackpad: [`[input]`](#input) · [Mouse reordering](#mouse-reordering)
- Visuals: [`[animation]`](#animation) · [`[overview]`](#overview) ·
  [`[decorations.borders]`](#decorationsborders) · [`[menu_bar]`](#menu_bar)
- [Multiple displays](#multiple-displays) · [Native fullscreen](#native-macos-fullscreen)
- Scripting: [CLI commands](#cli-commands) · [Event stream](#event-stream) ·
  [Diagnostics](#diagnostics)
- [Built-in defaults](#built-in-defaults) · [Unsupported configuration](#unsupported-configuration)

## Config file

Defi reads `~/.config/defi/config.toml` and reloads it on every save, including
the first one. It creates the config directory, but never the file. A reload
keeps your workspaces, focus, column widths, and scroll positions, and only
recalculates geometry when a changed setting affects it.

To use another file, start the daemon with `--config`:

```sh
/Applications/Defi.app/Contents/MacOS/defi-daemon --config /path/to/config.toml
```

When a change is invalid, Defi keeps the last valid configuration, shows an app
alert, and writes the error to `~/Library/Logs/Defi.log` (installed app).

<details>
<summary>What happens with each kind of error</summary>

Invalid TOML, values, workspace references, commands, accelerators, and `mod`
values are shown in an app alert. Errors that prevent decoding stop startup;
malformed hotkeys disable keyboard capture for that run. Configured mouse focus
and cursor-motion tracking remain active when possible. A well-formed key name
that the current keyboard layout does not have is not an error: only that
shortcut is inactive, and Settings says why.

</details>

## `[layout]`

Column sizes, width cycling, stacked window heights, where the focused column
sits, and gaps.

```toml
[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
preset_window_heights = [0.33, 0.50, 0.66]
center_focused_column = "never"
always_center_single_column = false
gaps = 8
outer_top_gap = 8
outer_right_gap = 8
outer_bottom_gap = 8
outer_left_gap = 8
reserved_top = 0
reserved_bottom = 0
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `default_column_width` | `0.80` | `0.05` to `1.0` | Width of each new column, as a fraction of the monitor. |
| `preset_column_widths` | `[0.33, 0.50, 0.66, 0.80]` | non-empty list, `0.05` to `1.0` | Widths that `cycle-width` steps through, wrapping at both ends. |
| `preset_window_heights` | `[0.33, 0.50, 0.66]` | non-empty list, `0.05` to `0.95` | Shares of the column height that `switch-preset-window-height` steps through for a stacked window, wrapping after the last. |
| `center_focused_column` | `"never"` | `"never"`, `"always"`, `"on-overflow"` | Where the focused column lands. See [Focused column centering](#focused-column-centering). |
| `always_center_single_column` | `false` | boolean | Centers a workspace's only column, in every mode. |
| `gaps` | `8` | `0` to `256` | Space between windows and around the monitor edges, in points. An outside border counts as part of its window. |
| `outer_top_gap`, `outer_right_gap`, `outer_bottom_gap`, `outer_left_gap` | `gaps` | `0` to `256` | Override the gap on one monitor edge. |
| `reserved_top` | `0` | `0` to `512` | Extra top inset below the macOS menu bar, for a status bar such as SketchyBar. |
| `reserved_bottom` | `0` | `0` to `512` | Extra bottom inset. |

Widths are fractions of the monitor's usable width: the monitor width minus the
left and right outer gaps, plus the space between two windows. Fractions that
add up to `1` fill the monitor exactly. When an app keeps a size a few points
off, such as a terminal sized to whole characters, a neighboring column absorbs
the difference. Widths you set by resizing a window stay in points and scale
with the monitor.

Reserved values are extra insets, not bar heights. See the
[SketchyBar integration](contrib/sketchybar/README.md) to compute them.

### Per-display column widths

A `[layout.monitors."<display name>"]` table overrides column widths on one
display, like Niri's per-output `layout`. Its name matches the display name
macOS shows in System Settings, as `rules.monitor` does, ignoring case. Settings
lists the connected displays under Layout.

```toml
[layout.monitors."DELL U3818DW"]
default_column_width = 0.40
preset_column_widths = [0.25, 0.40, 0.60]
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `default_column_width` | `layout.default_column_width` | `0.05` to `1.0` | Width of each new column on this display. |
| `preset_column_widths` | `layout.preset_column_widths` | non-empty list, `0.05` to `1.0` | Widths that `cycle-width` steps through on this display. |

The display a column is on decides: a window opens at that display's width, and
`cycle-width` and `maximize-column` use its presets and default. A column or
workspace moved to another display keeps its width until you change it there.
A display with no table, or one that is disconnected, uses `[layout]`. A reload
changes new columns only. Gaps and other `[layout]` keys stay global.

### Focused column centering

| Mode | When focus moves to another column |
| --- | --- |
| `"never"` | Scroll just enough to show it. |
| `"always"` | Center it, even the first or last column, which leaves empty space at the strip edge. |
| `"on-overflow"` | Center it only if it cannot share the screen with the previously focused column. Otherwise, act like `"never"`. |

<details>
<summary>Exact rules</summary>

- `"on-overflow"` measures the span from the left edge of the leftmost of the two
  columns to the right edge of the rightmost, every column between them and
  their gaps included. It fits when it is at most the usable width; an exact fit
  counts. The previous column holds the window Defi last scrolled to reveal on
  that workspace.
- Focus that jumps over other columns, such as `focus-column first`, measures the
  whole span and usually centers.
- With no previous column, such as the first window on a workspace or after the
  previous window closed, Defi scrolls only enough to reveal the new column.
- A column wider than the screen is left-aligned in every mode.
- `"on-overflow"` and `"never"` never leave edge space on their own.
- `always_center_single_column` applies while the workspace holds exactly one
  column. A second column ends it and the mode's normal rule takes over.
- `center-column` centers the focused column once, in any mode, and keeps it
  centered while the selection stays in that column, through width changes and
  focus moves inside a stack. Selecting another column drops it. Pressing it
  again changes nothing. It does nothing on an empty workspace or for a window in
  native fullscreen, and it leaves a floating selection in the floating layer.
- `center-visible-columns` scrolls once so the columns fully in view, taken
  together, sit in the middle of the screen: two 36 % columns at the left end
  up centered. Partially visible columns are not part of the group and may
  slide further out. It does nothing under `"always"` or, for a lone column,
  `always_center_single_column`, since the focused column is already centered.
  It also does nothing when the focused column is not fully in view, when the
  group fills the screen, when the group is already centered, on an empty
  workspace, or for a window in native fullscreen. The strip stays there while
  the selected column is fully in view, including after selecting another
  column of the group; a width change moves it only as far as keeps the
  focused column in view. Selecting a column outside the screen drops it, and
  the mode's normal rule takes over.
- Moving focus within one column keeps that column where it is. Focusing the
  selected window again changes nothing.
- The decision holds until the selected window changes. Moving the column or
  changing its width does not decide again, so a centered column stays centered
  and a revealed column is only kept visible.

</details>

## `[workspaces]`

Persistent named workspaces. Other workspaces come and go on their own.

```toml
[workspaces]
names = ["dev", "web", "tools"]
default = "dev"
monitors = { tools = 2 }
icons = { dev = "terminal", web = "globe" }
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `names` | `[]` | unique strings | Named workspaces, usable by rules and shortcuts. They stay even when empty. |
| `default` | first of `names` | a name from `names` | Workspace shown at startup on its monitor. |
| `monitors` | `{}` | name → 1-based display index | Puts a named workspace on a display by position. Others use the primary display. |
| `monitor_ids` | `{}` | name → display UUID | Same, by display identity. Settings writes it when you pick a screen there. |
| `icons` | `{}` | name → SF Symbol name | Icon shown in the menu bar, see [`[menu_bar]`](#menu_bar), and reported as `icon` by `list-workspaces --json` and the event stream. |

Use names without spaces: command arguments are split on whitespace, so a name
with a space cannot be used in shortcuts or the CLI. The `__defi_dynamic_`
prefix is reserved.

Named workspaces take the first number shortcuts. With
`names = ["dev", "web", "tools"]`, `mod-1` to `mod-3` jump to them, and `mod-4`
to `mod-9` address the other workspaces of the current monitor by position.
`mod-cmd-N` moves the focused column there and follows it. Positions are
1-based, do not wrap, and a position past the end selects the trailing
workspace.

**How workspaces behave**

- Each workspace belongs to one monitor, and every monitor keeps one empty
  workspace at the end. Filling it creates a new empty one; an empty workspace
  disappears once you leave it. Named workspaces stay.
- New windows open on the active workspace of their monitor, unless a rule
  sends them elsewhere. Defi does not remember an app's previous workspace after
  its windows close. Transient windows stay with their owner.
- Workspaces, focus, widths, and scroll positions survive a daemon restart
  within the same macOS login session.

<details>
<summary>Display affinity and reconnection</summary>

Settings shows each screen's localized name and stores its ColorSync display
UUID in `monitor_ids`, so reordering screens does not move the workspace.
Existing `monitors` entries keep using their display position; choosing a screen
in Settings converts that workspace to a UUID affinity. An unavailable display
stays pending.

If a display disconnects, its workspaces move to a fallback display and return
when the same display reconnects. Moving a workspace to another monitor
explicitly updates its affinity. When a second display connects as the primary
display for the first time in the session, it adopts the existing stack, active
workspace, and scroll state. Existing affinities and `monitors` entries take
precedence, and each display keeps its empty trailing workspace.

</details>

## `[[rules]]`

App rules send new windows to a workspace and override whether they tile or
float. Defi applies them when it first sees a window, including new windows of
an app already running. Saving a rule does not move windows already managed.

```toml
[[rules]]
app_id = "com.apple.iphonesimulator"
title = "Simulator"
role = "AXWindow"
workspace = "dev"
follow_focus = true
window = "force-tiled"
intrinsic_size = true
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `app_id` | unset | string | Bundle ID or app name, case-insensitive. Exact and suffix matches in either direction pass. |
| `title` | unset | string | Case-insensitive substring of the window title. |
| `title_regex` | unset | regular expression | Case-insensitive search in the window title, in ICU syntax. An invalid expression fails config load. |
| `role` | unset | string | Exact, case-sensitive Accessibility role, such as `AXWindow`. |
| `workspace` | unset | a name from `[workspaces].names` | Opens matching windows on this workspace. |
| `monitor` | unset | display name | Opens matching windows on the active workspace of this display. The name is the one in System Settings, matched ignoring case; the first display wins when names repeat. While that display is disconnected, windows open where they would without this rule. Cannot be combined with `workspace` in one rule. |
| `follow_focus` | `false` | boolean | Switches to that workspace when the new window has focus. |
| `open_focused` | unset | boolean | Unset keeps the default: a window the frontmost app opens takes focus. `false` opens it without focus or scrolling, and gives focus back to the previous window if the app takes it within a second. `true` focuses it and shows its workspace even when it opens in the background. Windows already open when Defi starts keep the default. |
| `window` | unset | `"force-floating"`, `"force-tiled"` | Overrides automatic placement. `"force-tiled"` also tiles windows Defi would float or ignore. Leave unset unless Defi places a window wrong. |
| `initial_column_width` | `layout.default_column_width` | `0.05` to `1.0` | Starting width of the window's column. Floating windows and `intrinsic_size` are unaffected. |
| `include_initial_width_in_cycle` | `false` | boolean | Adds `initial_column_width` to `cycle-width` for this app. |
| `intrinsic_size` | `false` | boolean | Keeps the window's own width and height inside its tile. |

A rule needs at least one of `app_id`, `title`, `title_regex`, or `role`, and
all the ones it sets must match. When several rules match, they combine in file
order: the last `workspace` or `monitor` wins, replacing an earlier one of the
other kind; the last `window`, `initial_column_width`, and set `open_focused`
win; and booleans combine with OR, so a later `false` cannot clear an earlier
`true`.

**Examples**

Float a browser's Picture-in-Picture window on an English system:

```toml
[[rules]]
app_id = "org.mozilla.firefox"
title = "picture-in-picture"
window = "force-floating"
```

Tile a terminal that hides its title bar buttons, which would otherwise float:

```toml
[[rules]]
app_id = "net.kovidgoyal.kitty"
window = "force-tiled"
```

Open a chat app on the built-in display without taking focus:

```toml
[[rules]]
app_id = "com.tinyspeck.slackmacgap"
monitor = "Built-in Retina Display"
open_focused = false
```

Open Device Hub at 44% and add that width to its `cycle-width` steps:

```toml
[[rules]]
app_id = "com.apple.dt.Devices"
initial_column_width = 0.44
include_initial_width_in_cycle = true
```

Prefer `app_id` alone when it is enough. Titles follow the system language,
and some apps set them just after opening a window. Defi checks the rules again
once, on the first new title within a second of opening, and places the window
as if it had opened with that title: `workspace`, `monitor`, `window`,
`initial_column_width`, and `intrinsic_size` apply, while the window keeps the
focus it already has, so `open_focused` and `follow_focus` do not. It skips this
if you moved, resized, or floated the window first. A title that changes later,
such as a browser tab's, never moves a window. `title` has no wildcards; use
`title_regex` for anchors or alternatives, such as
`title_regex = "^(Settings|Preferences)$"`.

<details>
<summary>Automatic floating and width details</summary>

Defi floats sheets, dialogs, modal windows, native floating panels, and standard
windows that are fixed-size, auxiliary, or offer neither an enabled full-screen
nor zoom button, such as Finder copy progress. Non-modal system-dialog and
system-floating windows are app-drawn menus or palettes and stay unmanaged;
`window = "force-floating"` still manages them. Floating windows keep their size
and position, park with their workspace, and stay on their monitor.
`window = "force-tiled"` also tiles the app's dialogs and fixed-size windows, so
add `title` when only one window needs it.

Initial widths do not override later manual resizing or widths restored on
daemon restart. Tiled windows still fill the available height.

`include_initial_width_in_cycle` has an effect only when a matching rule sets
`initial_column_width`; it never adds the global default width. The width is
inserted before the first larger preset, or at the end, without duplicates.
Cycling uses the focused window's rules, including in a shared column; other apps
keep the global presets. Reloaded rules affect the next cycle at once, without
resizing existing windows.

`window` replaced the `floating` and `force_tiling` rule keys. A file that
still sets them fails to load and names the replacement.

</details>

## `mod`

The modifiers behind `mod`. Every built-in shortcut uses it, and so can yours.

```toml
mod = "ctrl+alt+cmd"

[keys]
"mod-d" = "diagnostic-mark"
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `mod` | `"ctrl+alt"` | modifier names joined by `+` | Modifiers that `mod` stands for in every shortcut. |

| Modifier | Accepted names |
| --- | --- |
| Command | `cmd`, `command` |
| Option | `alt`, `option` |
| Control | `ctrl`, `control` |
| Shift | `shift` |

Names and order are case-insensitive. Settings › Input › Mod key sets the same
value.

The built-in shortcuts form three layers: `mod` focuses, `mod-cmd` moves the
focused column or window, and `mod-shift` reaches other monitors and reorders
workspaces. A layer uses a modifier that `mod` lacks: moving takes Command, or
Shift when `mod` already holds Command, and the monitor layer takes the other
one when it is free. With a Hyper `mod` (`ctrl+alt+cmd`), `mod-shift` moves and
the monitor layer is unbound; with all four modifiers, both are unbound.

<details>
<summary>How a new <code>mod</code> interacts with other shortcuts</summary>

Changing `mod` moves every built-in shortcut, and every `mod-` shortcut you
wrote, to the new modifiers. If `mod` already includes Shift or Command, the
shortcut with fewer added modifiers wins the chord they share. Your own `[keys]`
entries still win.

`mod` replaced `default_key_modifier` and `[modifier_combinations]`. A file
that still sets them fails to load and names the replacement.

</details>

## `show_cheatsheet_on_modifier_hold`

Defaults to `true`: hold the `mod` modifiers alone for 600 ms to see your
shortcuts on the active monitor. Releasing a modifier closes it. Adding another
modifier or pressing a key before the delay cancels it.

To use a shortcut instead, or as well:

```toml
show_cheatsheet_on_modifier_hold = false

[keys]
"mod-slash" = "toggle-cheatsheet"
```

`toggle-cheatsheet` is bound to `mod-shift-slash` (`mod-?`). It keeps the help open until you
toggle it again, press Escape, click, or run any Defi shortcut. After a
shortcut, release the modifiers before holding them again. Reloading the
configuration and display or session changes also close it.

Settings › Input › Modifiers controls whether the `mod` combination shows as
`✧` in Settings and the cheatsheet. It does not change any shortcut. The
cheatsheet fade follows `[animation].enabled` and Reduce Motion.

## `[keys]`

Binds shortcuts to [commands](#commands). Your entries merge with the
[built-in shortcuts](#built-in-defaults): the same shortcut replaces the
built-in one, and the others stay.

```toml
[keys]
"mod-left" = "focus-column left"
"mod-shift-1" = "move-window-to-workspace dev"
```

To turn a built-in shortcut off, list it in the root-level `disabled_keys`:

```toml
disabled_keys = ["mod-left"]
```

Settings can change, disable, and restore built-in shortcuts for you. It writes
the same `[keys]` and `disabled_keys` entries.

A shortcut that another app already holds is skipped and shows "Held by another
app" in Settings; the others keep working. Defi retries it when the keyboard
layout changes or the configuration reloads. Shortcuts stay silent while
another app captures the keyboard.

<details>
<summary>How Defi captures shortcuts</summary>

Defi reserves shortcuts with Carbon global hotkeys and observes input through a
passive event tap, so commands stay responsive while the main event loop is
busy, and Defi's tap never discards normal shortcut events. Reservations pause
while you record a shortcut or edit text in Defi. If no shortcut registers at
all, shortcuts are disabled and the failure appears in Settings and in an app
alert; input observation stays active. A separate filtering tap handles Overview
navigation, shortcut recording, help dismissal, and pointer routing.

</details>

### Accelerator syntax

Write a shortcut as `<modifier>-<modifier>-<key>`, where a modifier is a name
from the [`mod`](#mod) table or `mod` itself. Order and case do not matter.
Examples: `alt-left`, `cmd-shift-p`, `mod-backslash`.

The key is one of these names, or any other single character, such as
`ctrl-alt-é`. `ctrl-alt-[` and `ctrl-alt-leftbracket` are the same shortcut.

| Kind | Names |
| --- | --- |
| Letters | `a` to `z` |
| Digits | `0` to `9` |
| Arrows | `left`, `right`, `up`, `down` |
| Navigation | `tab`, `home`, `end`, `pageup`, `pagedown` (Fn with an arrow on keyboards without them) |
| Punctuation | `minus`, `equal`, `leftbracket`, `rightbracket`, `semicolon`, `quote`, `backslash`, `comma`, `period`, `slash` |

### Keyboard layouts

Shortcuts follow your keyboard layout and update when it changes:

| Key | Where it lands |
| --- | --- |
| Digits, arrows, Tab, and navigation keys | Always the same physical key. `ctrl-alt-1` stays on the number row on AZERTY. |
| Letters | The key printing that letter, such as `ctrl-alt-f` on Dvorak. A layout without the letter keeps the US position. |
| Punctuation | The key printing the character, adding Shift or Option when it needs them: `ctrl-alt-period` is `⌃⌥⇧;` on French. |
| Other characters | The key printing the character. If the layout lacks it, only that shortcut is inactive. |

The cheatsheet and Settings show the key you actually press. An inactive
shortcut reads "Not on this layout", "Held by" the shortcut that owns its key,
or "Held by another app".

<details>
<summary>Conflicts, fallbacks, and special keyboards</summary>

Defi reads the active ASCII-capable layout, so switching between Romaji and kana
changes nothing. Where the layout is unavailable, every key name stays on its US
position.

`leftbracket` and `rightbracket` with the same modifiers move together: if
either would need added modifiers, both take their US positions when free
(`⌃⌥^` and `⌃⌥$` on French). A name written with Shift, such as
`ctrl-alt-shift-minus`, takes the key of its unshifted sibling when that sibling
needs no added modifiers and the chord is free. If a punctuation chord is taken,
Defi tries the key's US position, then the first main-block key that is free
with the modifiers as written, so a default shortcut is never lost. That search
tries keys printing a symbol first, then letters, then digits, lowest key number
first within each. Keys the keyboard lacks (§ off ISO keyboards, ¥ and _ off
JIS) are never used. A character whose key is held by another shortcut (digits
and arrows win) is inactive, and the others are unaffected.

Chords are claimed in this order: digits and arrows, characters on the
unmodified key, bracket pairs on their US positions, characters that need Shift
or Option, US positions, then the free-key search. Ties break by accelerator
name, so the result never depends on the order of the file. A shortcut you wrote
in `[keys]` claims its digit, arrow, or character before any built-in one, so on
French `ctrl-alt-é` keeps the key of the digit 2 and the default `ctrl-alt-2`
reads "Held by" it. A displaced default moves on to its own fallbacks. The
keypad is never used.

Shortcuts containing `cmd` read the layout as Command sees it, which matters on
Dvorak-QWERTY⌘. So does Defi's detection of Command-Q and Command-W as a window
about to close.

Defi logs one line per inactive shortcut whenever the table changes. The
Settings recorder stores a name that resolves back to the pressed key on the
current layout, and refuses a shortcut whose key another shortcut already holds,
even when the names differ.

The layout is read for the keyboard type of the last key pressed. With an ANSI
and a JIS keyboard attached at once, shortcuts re-resolve when you switch
keyboards, so the first key from the other one still follows the previous table.
Settings reads the same type but only refreshes when the input source changes.

</details>

### Commands

Shortcuts and the `defi` CLI use the same command strings. Named targets must be
declared in `[workspaces].names`; rules cannot target dynamic positions.
"Unset" means no built-in shortcut.

**Focus**

| Command | Description | Built-in shortcut |
| --- | --- | --- |
| `focus-column left\|right` | Focus the previous or next column. | `mod-left` / `mod-right`, `mod-h` / `mod-l` |
| `focus-column first\|last` | Focus the first or last column. | `mod-home` / `mod-end` |
| `focus-window up\|down` | Focus the previous or next window in the stack. | `mod-up` / `mod-down`, `mod-k` / `mod-j` |
| `focus-window first\|last` | Focus the first or last window in the stack. | unset |
| `focus-window-or-workspace up\|down` | Like `focus-window`, but past the top or bottom of the stack, focus the adjacent workspace. | unset |
| `focus-window-previous` | Go back to the window focused before this one, on any workspace or monitor. | unset |
| `recent-windows next\|previous` | Open the recent windows switcher, or move its selection forward or backward, wrapping. | `mod-tab` / `mod-shift-tab` |
| `recent-windows confirm\|cancel` | Focus the selected window and close the switcher, or close it without changing anything. | unset |
| `focus-floating previous\|next` | Focus the previous or next floating window, wrapping. | `mod-shift-comma` / `mod-shift-period` |
| `focus-floating first\|last` | Focus the first or last floating window. | unset |
| `activate-floating` | Select the floating layer and bring its selected window forward. | `mod-shift-v` |
| `focus-monitor left\|right\|up\|down` | Focus the nearest monitor in that direction. | `mod-shift-<arrow>`, `mod-shift-h/j/k/l` |
| `focus-column-or-monitor left\|right` | Like `focus-column`, but past the first or last column, focus the next monitor. | unset |

**Workspaces**

| Command | Description | Built-in shortcut |
| --- | --- | --- |
| `focus-workspace up\|down` | Focus the adjacent workspace, without wrapping. | `mod-i` / `mod-u`, `mod-pageup` / `mod-pagedown` |
| `focus-workspace-position <n>` | Focus a 1-based position, clamped to the trailing workspace. | `mod-1` … `mod-9` after named ones |
| `workspace <name>` or `focus-workspace-name <name>` | Focus a named workspace, on any monitor. | `mod-1` … `mod-9` for named ones |
| `focus-workspace-previous` | Go back to the workspace this monitor showed before. | unset |
| `reorder-workspace up\|down` | Move the active workspace up or down its monitor's stack. | `mod-shift-i` / `mod-shift-u`, `mod-shift-pageup` / `mod-shift-pagedown` |
| `move-workspace-to-monitor left\|right\|up\|down` | Move the active workspace to another monitor and remember it there. | unset |

**Move columns and windows**

| Command | Description | Built-in shortcut |
| --- | --- | --- |
| `move-column left\|right` | Move the focused column. | `mod-cmd-left` / `mod-cmd-right`, `mod-cmd-h` / `mod-cmd-l` |
| `move-column first\|last` | Move the focused column to the start or end. | `mod-cmd-home` / `mod-cmd-end` |
| `move-window up\|down` | Move the focused window inside its stack. | `mod-cmd-up` / `mod-cmd-down`, `mod-cmd-k` / `mod-cmd-j` |
| `move-column-to-workspace up\|down\|<name>` | Move the focused column to a workspace and follow it. | `mod-cmd-i` / `mod-cmd-u`, `mod-cmd-pageup` / `mod-cmd-pagedown` |
| `move-column-to-workspace-position <n>` | Same, by position. | `mod-cmd-1` … `mod-cmd-9` after named ones |
| `send-column-to-workspace up\|down\|<name>` | Move the focused column without following it. | unset |
| `move-window-to-workspace up\|down\|<name>` | Move only the focused window and follow it. | unset |
| `move-window-to-workspace-position <n>` | Same, by position. | unset |
| `send-window-to-workspace up\|down\|<name>` | Move only the focused window, without following it. | unset |
| `send-window-to-workspace-position <n>` | Same, by position. | unset |
| `move-column-to-monitor left\|right\|up\|down` | Move the focused column to the nearest monitor. | `mod-shift-cmd-<arrow>`, `mod-shift-cmd-h/j/k/l` |
| `move-column-or-to-monitor left\|right` | Like `move-column`, but past the first or last column, move it to the next monitor. | unset |
| `move-window-to-monitor left\|right\|up\|down` | Move only the focused window to the nearest monitor. | unset |

When a workspace is named `up` or `down`, use `move-column-to-workspace-name
<name>` or `move-window-to-workspace-name <name>`.

**Widths and stacks**

| Command | Description | Built-in shortcut |
| --- | --- | --- |
| `cycle-width previous\|next` | Step through `preset_column_widths`, wrapping. | `mod-minus` / `mod-equal`; `mod-r` also steps forward |
| `maximize-column` | Toggle the focused column between full width and its previous width. | `mod-f` |
| `set-column-width <width>` | Set the width: `60%` of the usable width, `960` points, or relative, such as `+5%`, `-10%`, or `-40`. | unset |
| `expand-column-to-available-width` | Grow the focused column into the free space beside the other fully visible columns. | unset |
| `set-window-height <N%\|+N%\|-N%\|points>` | Set the focused stacked window to `N%` of the column height, change its share by `N` percentage points, or make it `points` tall. The rest of the stack absorbs the difference and keeps its relative heights. | unset |
| `switch-preset-window-height` | Give the focused stacked window the next height in `preset_window_heights`, wrapping. | unset |
| `reset-window-height` | Split the focused stack evenly again. | unset |
| `center-column` | Center the focused column until you select another one. | `mod-c` |
| `center-visible-columns` | Center the columns fully in view as one group, while the selected column stays in view. | unset |
| `join-window left\|right` | Add the focused window to the stack on the left or right. | `mod-semicolon` / `mod-quote` |
| `unjoin-windows` | Split the focused window out of its stack into a new column. | `mod-period` |
| `consume-or-expel-window left\|right` | Alone in its column, the focused window joins the stack on that side, like `join-window`. In a stack, it leaves as a new column on that side. | `mod-leftbracket` / `mod-rightbracket` |
| `swap-window left\|right` | Swap the focused window with the one at the same row of the adjacent column, or its last window when that column is shorter. Columns keep their widths. | unset |
| `toggle-floating` | Switch the focused window between tiled and floating. | `mod-v` |

**Other**

| Command | Description | Built-in shortcut |
| --- | --- | --- |
| `toggle-overview` | Open or close the Overview. | `mod-o` |
| `toggle-cheatsheet` | Open or close the shortcut help. | `mod-shift-slash` |
| `open-settings` | Open Settings, even with the menu bar item hidden. | unset |
| `diagnostic-mark` | Record the current status and recent trace, without changing windows. See [Diagnostics](#diagnostics). | unset |

`previous` may be written `prev`. `focus-column` and `focus-window` also accept
`previous`/`next`, and `focus-floating` accepts `left`/`right` and `up`/`down`.
Commands are checked when the config loads; some direction checks happen when
the command runs, so prefer the forms listed above.

<details>
<summary>Details: going back, widths, and stacks</summary>

**Going back.** `focus-workspace-previous` returns to the workspace this monitor
showed before the active one; press it again to go back. Any change of the
active workspace counts, including a click, the Dock, Command-Tab, and the
Overview. Each monitor keeps one entry. Nothing happens when that workspace is
gone or has moved to another monitor.

`focus-window-previous` returns to the managed window that held focus before the
current one and activates its workspace; press it again to go back. Any
committed focus change counts, including a click, the Dock, Command-Tab, and the
Overview; windows passed over during rapid navigation do not. If the current
window closes, the entry stays on the last window still open. Nothing happens
when the previous window has closed or left Defi's management; an older window
still open is chosen instead. The history survives daemon restarts in the same
macOS session.

**Recent windows.** `mod-tab` works like Command-Tab, but per window and across
every workspace and monitor. While `mod` stays held, each Tab moves forward
through the windows by latest focus, followed by windows never focused, and
`mod-shift-tab` moves back. Releasing `mod` focuses the selected window and
activates its workspace, like `focus-window-id`; Escape closes the switcher
without changing anything. The switcher appears after 150 ms, without animation,
on the active monitor, so a brief `mod-tab` goes back to the previous window
like `focus-window-previous` without showing anything. Moving through the list
does not focus the windows or change the history.

Cards show the window picture the animations and the Overview keep, or the app
icon when there is none, when Screen Recording is missing, or with
`[overview].window_previews = false`. A window that closes leaves the list, and
the selection moves to the next one. Holding `mod` with the switcher open never
opens the cheat sheet. Any other command, the Overview, a display change, or
locking the screen closes the switcher without choosing. While the Overview is
open, `recent-windows next` and `previous` fail. From the CLI, `recent-windows
next` opens the switcher until `recent-windows confirm` or `cancel`.

`focus-window-or-workspace` gives the new workspace its remembered selection. It
also switches workspace with no tiled window selected, stops at the first
workspace without wrapping, and moves a floating selection beside tiled columns
to the tiled layer like `focus-window`.

**Columns or monitors.** `focus-column-or-monitor` also switches monitor from an
empty workspace, and that monitor keeps its remembered selection. A floating
selection returns to the tiled layer like `focus-column`.
`move-column-or-to-monitor` lands the column after the other monitor's focused
column and keeps the focus. With no monitor in that direction, both behave
exactly like `focus-column` and `move-column`.

**Widths.** Width commands respect the usable width and each window's verified
minimum and maximum width. `set-column-width` clamps to the whole usable width,
at least 5% of it, and those bounds. A percentage stays a share of the usable
width when the monitor changes; a point width follows the monitor like a width
set by a native resize. It ends a maximized state, so `maximize-column` then
maximizes again.

`expand-column-to-available-width` resizes no other column. The fully visible
columns stay in view, the ones after it sliding over by its growth, and partly
visible columns move out of view. It does nothing when the focused column is not
fully visible or no space is free.

After either command, `cycle-width` steps to the nearest preset in its
direction, as after a native resize: from `60%`, `next` selects `0.66` and
`previous` selects `0.50`.

**Stacks.** A stack splits its column's height evenly, after gaps, until a
height command or a native resize gives its windows their own proportions.
Dragging a stacked window's top or bottom edge moves only the neighbour across
that edge; the stack's outer edges stay at the column edges. A height command
scales all the other windows of the stack. Every window keeps at least 5% of the
column, a window joining a resized stack gets the average share, and the
proportions follow the windows when they are reordered or one closes. They are
kept with the session state across daemon restarts. A single tiled window always
fills the column, so height commands change nothing there.

A window's verified minimum height still forces a taller slot and its maximum
still caps it; the others share the rest by their proportions. When every window
is capped, the spare height is spread evenly and each window is centered in its
slot.

`join-window` is refused, with the required and available height in the error,
when the stack would need more than the usable height. `consume-or-expel-window`
and `swap-window` are refused the same way when a resulting stack would not fit.
After either command, focus stays on the window that moved; both do nothing at
the end of the strip. If a monitor shrinks or a
constraint changes so a stack no longer fits, Defi keeps the longest
top-to-bottom run that fits and moves the rest, in order, into new columns of
the same width on its right. Columns are never merged back automatically. A
single window whose minimum height exceeds the usable height (which excludes the
Dock and reserved areas) is placed at its minimum, top-aligned, and listed in
`oversized-stack-windows` of `defi status`.

</details>

## `[input]`

Focus that follows the pointer, a pointer that follows focus, and trackpad
swipes.

```toml
[input]
focus_follows_mouse = false
focus_follows_mouse_max_scroll_amount = 0.0
focus_follows_mouse_delay_ms = 50
mouse_follows_focus = false
scroll_gestures = false
# scroll_gesture_modifier = "ctrl+alt"
scroll_gesture_fingers = 2
scroll_gesture_speed = 1.0
scroll_gesture_snap = true
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `focus_follows_mouse` | `false` | boolean | Focuses the managed window under the pointer. |
| `focus_follows_mouse_max_scroll_amount` | `0` | `0` to `1` | How far the strip may scroll to do so, as a fraction of the monitor width. `0` focuses only windows already fully in view; `0.1` allows up to 10%. |
| `focus_follows_mouse_delay_ms` | `50` | `0` to `1000` | How long the pointer must rest first, in milliseconds. `0` focuses at once. |
| `mouse_follows_focus` | `false` | boolean | Moves the pointer to the center of a window you focus with the keyboard, unless it is already inside. |
| `scroll_gestures` | `false` | boolean | Moves the strip with trackpad swipes, and with the mouse wheel while the modifier is held. |
| `scroll_gesture_modifier` | `mod` | modifiers like `mod`, or `"none"` | Modifier held to start a swipe. `"none"` needs three or four fingers and turns the mouse wheel off. |
| `scroll_gesture_fingers` | `2` | `2`, `3`, `4` | Fingers that swipe the strip. Two-finger swipes are scrolls, so they need the modifier. |
| `scroll_gesture_snap` | `true` | boolean | Settles a sideways swipe on a column. `false` leaves the strip where the swipe stops. |
| `scroll_gesture_speed` | `1.0` | `0.25` to `4` | Multiplies how far a swipe moves the strip and the workspaces. |

Pointer-driven focus never moves the pointer, and CLI commands and native app
focus changes never do either, so the two options can run together without
feedback loops.

### Scroll gestures

With `scroll_gestures`, a swipe with `scroll_gesture_fingers` fingers that
starts with the modifier held works on the display under the pointer:

- **Sideways**, the strip follows your fingers, with a rubber band past the first
  or last column. On release, the nearest column takes focus and is placed as
  `center_focused_column` would place it. A flick reaches the next column at
  most.
- **Vertically**, the workspaces follow your fingers, one above or below at most.
  On release, the switch completes or springs back, depending on where the flick
  would stop.
- A **mouse wheel** focuses one column per notch sideways (or with Shift), and one
  workspace per notch vertically, at most one every 150 ms.

<details>
<summary>Gesture details</summary>

- With `scroll_gesture_snap = false`, the strip stays where the swipe stops,
  momentum included, within the strip's ends. The column fully in view nearest
  the middle takes focus; if none is fully in view, the strip slides just enough
  to show the nearest one. The strip keeps that position, whatever
  `center_focused_column` says, until focus leaves the column.
- The first 16 points of a swipe pick its axis for the whole gesture.
- The same finger travel crosses the same share of any display. On a 1,512-point
  laptop display the strip follows two fingers about one to one at the default
  speed. With three or four fingers, a swipe across the whole trackpad moves the
  strip two displays.
- Defi keeps a gesture that starts with the modifier, momentum included, until it
  ends, so the app under the pointer never sees part of it (no half-started
  swipe back in a browser). A gesture that starts without the modifier stays the
  app's, even if the modifier is pressed later.
- Defi only reads three- and four-finger swipes, so it leaves alone each
  direction macOS gives them in Trackpad settings (Mission Control, Spaces,
  three-finger drag), read again at the start of each swipe. Three- and
  four-finger swipes move the strip with the fingers, whatever the scrolling
  direction setting.
- Without Screen Recording permission or with animations off, the strip moves
  once the fingers lift.
- Moving the pointer uses a CoreGraphics API that emits no mouse-moved event.
  Defi drops a delayed pointer move when you moved the pointer after the
  keyboard command.

</details>

## Mouse reordering

Drag a tiled window by its title bar to move it. As the drag starts, the other
windows close up the place it leaves, once; then nothing moves until the release.
A translucent band marks where the window would land, and releasing moves
everything once to put it there.

- The closest edge to the pointer wins: a gap between two columns opens a new
  column there; a border between two windows of the column under the pointer, or
  that column's bottom, adds the window to its stack there.
- Another column's top counts once the pointer enters the menu bar above it, or
  reaches the screen's top edge: a title bar crossing columns runs along their tops.
  In the window's own stack, its top counts like any border.
- The dragged window stops at the menu bar, as macOS keeps a real window below it.
- The pointer still counts as over the strip under the menu bar or beside the Dock.
- The band follows the pointer at once, every frame, and releasing drops where it
  shows. The strip scrolls after a drop only when the dropped window would
  otherwise sit partly off screen.
- A stack the window cannot fit in gets a red outline, and dropping there
  changes nothing.

Without the overlay, the outline and preview are missing but the drop behaves
the same. Resizing a window changes its width, never the order. When you press
on a neighboring column, the strip waits for the release before scrolling, so
it stays still while Defi tells a click from a drag.

Hold the dragged window within 48 points of the left or right edge of its display
for a quarter second and the strip scrolls that way, faster the closer the pointer
sits to the edge, until it reaches the strip's end or the pointer moves away.

- The zone reaches the display's edge past a side Dock; moving onto a neighboring
  display drops there instead.
- While the pointer is in the zone, the drop only creates a new column, so columns
  sliding under a still pointer never stack the window by accident.
- The scroll is drawn on the overlay alone: without Screen Recording the strip
  does not scroll.
- Release commits the drop at the scrolled position, then the strip reveals the
  dropped column from there.

## `[animation]`

Defi animates windows on an overlay: column navigation, width and order
changes, stacking, opening and closing windows, mouse drops, click-to-focus
scrolling, and workspace switches.

```toml
[animation]
enabled = true
stiffness = 800
damping_ratio = 0.9
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Animates windows on the overlay. `false` moves windows at once and takes no pictures. |
| `stiffness` | `800` | `100` to `2000` | Spring stiffness of every motion. Higher is faster. |
| `damping_ratio` | `0.9` | `0.5` to `1` | `1` never overshoots. Lower values arrive sooner and overshoot slightly. |

The overlay draws pictures of your windows while each real window moves once,
underneath, to its target. Motion never waits on a slow app. It needs Screen
Recording, which Defi requests once Accessibility is granted. Without it, with
Reduce Motion on, or when the overlay cannot draw a motion yet (for example
before the wallpaper is captured), windows move at once.

Screen recordings, screenshots, and screen sharing include the overlay, so they
show the motion you see.

<details>
<summary>How the overlay works</summary>

Proxies follow the spring and keep their position and velocity when a new
command retargets them. Each display has its own overlay, and a command moves
only the displays it changes. Pictures of visible windows refresh after each
landing, never at rest, and fill resized proxies without stretching. The app icon
is laid over a missing picture, or over an old one arriving from another
workspace, and the overlay fades into the real windows.

The spring changes only how the overlay draws a motion; each window still moves
once. The default `damping_ratio` reaches 90% of the travel about 12% sooner
than `1` and lands a column step visibly about 0.1 s earlier, overshooting by
under 0.2% of the travel (about 2 points on a full-display move).

</details>

## `[overview]`

The Overview scale and what its window cards show.

```toml
[overview]
zoom = 0.5
window_previews = true
window_corner_radius = 12
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `zoom` | `0.5` | `0` to `0.75` | Scale of workspaces and windows. Lower values show more of the neighboring workspaces. |
| `window_previews` | `true` | boolean | Shows window pictures in cards. With `[animation].enabled = false` too, Defi takes no pictures at all. |
| `window_corner_radius` | `12` | `0` to `64` | Corner radius of window cards and their borders. |

Opening the Overview zooms your windows out to their cards, and closing it zooms
them back, with or without previews. Reduce Motion or
`[animation].enabled = false` switches without zooming.

Dragging a tiled card onto the outer quarter of a column creates a new column
beside it; its middle half adds the card to the stack, at the height of the
pointer. The Overview shows the result at once, and real windows only move to
the final layout.

Defi asks for Screen Recording right after Accessibility. If it is still missing
and `window_previews = true`, it asks once more before the first Overview, so the
panel does not cover the prompt. If access is denied, revoked, or unavailable, the
Overview opens with plain cards, without an error, and Defi does not ask again
until the daemon restarts. Settings ›
General shows the permission.

<details>
<summary>Window pictures and memory</summary>

Animations and the Overview share one picture per window, refreshed by one rule
under one memory budget. Pictures are one-shot screenshots taken on events (a
landing, a layout, a resize, an Overview opening), never continuous capture, and
each consumer scales the same picture on the GPU. Opening the Overview shows the
pictures it already has at once and refreshes the cards in view. The zoom uses
each visible window's full-resolution picture when its size still matches.

Pictures stay in memory and contain no audio or cursor. The cache holds up to
128 MiB of full-resolution pictures: the most recently shown windows keep full
resolution, older ones shrink to 1,024 pixels on their longest edge and, when
compressible, keep their full pixels compressed; smaller ones are dropped past
the cap. A memory pressure warning lowers the cap to a quarter, never below
twice the displays' pixels; critical pressure releases every picture. Defi
checks the window and process identity before showing a picture. Closed
Overview panels and their desktop images are released right after the closing
animation.

A window without a picture animates as a placeholder card from its verified
frame. Protected content and capture errors leave the cards fully usable. When
permission, geometry, or a missing picture prevents a complete zoom, windows
zoom as placeholder cards or the plain Overview opens instead. Changing the
Overview projection returns to plain card previews. Escape zooms back when
native frames and Overview offsets are unchanged; selecting another window or
workspace uses the normal path. Freshness during typing or animated content,
shadows, widgets, and native fullscreen windows remain limits.

Sharing a whole display can include the Overview and the content in its cards;
sharing one app or window normally does not include Defi's overlay.

</details>

## `[decorations.borders]`

Borders around visible tiled windows.

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

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Draws a border around the focused tiled window. |
| `width` | `4` | `0` to `64` | Border width, in points. |
| `color` | `"#FFC099FF"` | `#AARRGGBB` or `0xAARRGGBB` | Focused-window border color. |
| `inactive_enabled` | `false` | boolean | Also draws borders around the other visible tiled windows. |
| `inactive_color` | `"#66C099FF"` | `#AARRGGBB` or `0xAARRGGBB` | Color of those borders. |
| `placement` | `"outside"` | `"outside"`, `"inside"` | Draws the border just outside the window, or over its outer pixels. |
| `capture_enabled` | `false` | boolean | Shows borders in screenshots and screen recordings, for debugging. |

Colors take exactly eight hex digits, alpha first, then red, green, and blue, in
either case.

With `placement = "outside"`, every tiled window reserves one border width on
each side, drawn or not, and gaps start at the border's outer edge. With
`gaps = 0` and `width = 4`, borders touch the monitor edges and neighboring
windows sit 8 points apart. Two 50% columns still fill the monitor exactly. With
`"inside"`, the border covers the window's edge and takes no space.

Parked, inactive-workspace, and floating windows never get borders. Borders
ignore clicks and, with `capture_enabled = false`, need no Screen Recording
permission.

<details>
<summary>Implementation notes</summary>

Defi uses native WindowServer bounds and corner radii when available, with
Accessibility-frame and stable-radius fallbacks. With `capture_enabled = false`,
border surfaces use `NSWindowSharingNone`.

</details>

## `[menu_bar]`

Defi's menu bar item.

```toml
[menu_bar]
enabled = true
workspace_style = "name"
```

| Setting | Default | Values | Description |
| --- | --- | --- | --- |
| `enabled` | `true` | boolean | Shows the menu bar item. Turn it off when SketchyBar shows your workspaces; `defi open-settings` still opens Settings. |
| `workspace_style` | `"name"` | `"name"`, `"icon"`, `"icon_and_name"` | How named workspaces appear. Others always show their number. |

Icons come from `[workspaces].icons`. They follow workspace renames and are
removed when you delete a workspace in Settings. A named workspace without an
icon, or with a symbol this macOS version lacks, shows `square.grid.2x2`.

```toml
[workspaces]
names = ["dev", "web"]
icons = { dev = "terminal", web = "globe" }

[menu_bar]
workspace_style = "icon_and_name"
```

## Multiple displays

Each display has its own workspaces, focus, and strip. Displays stacked
vertically keep their native arrangement. When displays sit side by side, a
partly visible column would spill onto the next display, so Defi moves the
displays into a temporary corner-to-corner staircase while it runs. Mirrored
displays are left unchanged.

Commands, the pointer, and window moves still follow the arrangement you chose in
System Settings, which Defi calls the desk. When the pointer reaches an edge
shared on the desk, Defi moves it to the matching point of the neighboring
display, while moving or dragging. Change the arrangement in System Settings at
any time; Defi adopts it as the new desk. While System Settings is the active
app, Defi lifts the staircase so Displays shows and edits the desk, and puts the
staircase back when you switch away.

When you connect another set of displays, such as a monitor at home and another
at the office, the desk is the arrangement macOS restores for that set, as it
would without Defi. Defi tells displays apart by their hardware identity, so a
different monitor never inherits another one's side.

`defi status` reports `displayArrangement` and `displayPointerWarps`:

| `displayArrangement` | Meaning |
| --- | --- |
| `native` | The desk needs no staircase. |
| `isolated` | The staircase is active and the pointer follows the desk. |
| `suspended` | System Settings is active, so the desk is shown without the staircase. |
| `ambiguous` | The displays already form Defi's staircase and no desk is known. Defi keeps native pointer movement. Rearrange the displays in System Settings › Displays to fix it. |
| `observation-mismatch` | macOS accepted the change but reported other display frames. Defi restores the previous arrangement and keeps native pointer movement until a later change succeeds. |
| `failed:<code>` | macOS refused the change. Defi keeps native pointer movement until a later change succeeds. |

<details>
<summary>How the staircase and hidden windows work</summary>

Defi restores the desk for the login session when it stops, so the restoration
outlasts the process. The staircase uses the CoreGraphics application-lifetime
scope, so macOS also returns to the desk if Defi quits unexpectedly. On start,
Defi applies the staircase again only when the desk needs it. It saves the desk
for the login session and recovers it if macOS keeps the staircase across a
restart. Defi never adopts its own staircase as the desk. Other apps see the
staircase coordinates while Defi runs. Resolution and main-display changes keep
the existing desk. If macOS restores Defi's staircase for a set of displays,
Defi uses the desk it last saw for that set.

Pointer moves between displays work with or without `focus_follows_mouse` and
`mouse_follows_focus`.

Hidden windows are windows of inactive workspaces and columns scrolled out of
view. Each waits in a corner or along an edge of its own display, with one point
of its edge left on that display, or its title bar along the bottom edge. Defi
picks the first spot clear of every other display, or the one that overlaps them
least, using the staircase frames while it is active.

</details>

## Native macOS fullscreen

`maximize-column` only widens a column. It does not enter native fullscreen or
create a macOS Space. Native fullscreen stays under the control of macOS and
the app:

- While a window is in native fullscreen, Defi takes it off the strip and stops
  moving, parking, bordering, or focusing it automatically. It keeps the
  window's column slot, width, monitor, workspace, and selection; explicit focus
  commands can still select it.
- When it exits, Defi puts it back in its slot, or on a fallback monitor if the
  original one is gone.
- A late fullscreen event never restores an older layout, visibility, or focus.

## CLI commands

Every [command](#commands) also runs from the `defi` CLI, which ships inside the
app at `/Applications/Defi.app/Contents/MacOS/defi`. These commands are
CLI-only:

| Command | Description |
| --- | --- |
| `status` | Print Defi's current state. |
| `list-workspaces` | Print workspace labels per display. Add `--json` for versioned identity, position, name, icon, kind, and app state. `icon` is the configured SF Symbol name, absent when none is set. |
| `list-windows` | Print one managed window per line: ID, app name, and title. Add `--json` for bundle ID, workspace, display, column, row, floating, and focus. |
| `focus-window-id <id>` | Focus a window by its `list-windows` ID, switching its display to its workspace. |
| `subscribe --json` | Keep the connection open and print one JSON event per line. See [Event stream](#event-stream). |
| `--monitor <index> <command>` | Run a command on a display, by its 1-based `NSScreen.screens` / SketchyBar index. |
| `set-reserved-area top\|bottom <points>` | Override the reserved edge on every display, or on one with `--monitor`. |
| `clear-reserved-area` | Restore the configured reserved edges. |
| `triage [--agent claude\|codex]` | Write machine facts and a support playbook to `~/Library/Application Support/Defi/triage/`, then start `claude` or `codex` to investigate a problem and draft an issue. Never sent to the daemon. |

`list-windows` and the event stream include window titles. They are served only
over the per-user Unix socket and never written to diagnostics files. See the
[SketchyBar integration](contrib/sketchybar/README.md) for example scripts.

### Event stream

`defi subscribe --json` first prints a `snapshot` event, with the same
`workspaces` object as `list-workspaces --json` and the same `windows` array as
`list-windows --json`, then one line per change. Every line has `version`
(currently 1) and `event`:

| Event | Fields | Sent when |
| --- | --- | --- |
| `snapshot` | `workspaces`, `windows` | on connect |
| `monitors-changed` | `workspaces` | a display connects, disconnects, or changes order |
| `workspaces-changed` | `workspaces` | any workspace state changes, including activation, names, icons, order, and occupancy |
| `workspace-activated` | `monitorID`, `display`, `workspace` | a display shows another workspace |
| `window-opened` | `window` | Defi starts managing a window |
| `window-closed` | `windowID` | Defi stops managing a window |
| `window-moved` | `window` | a window's workspace (including its position or name), display, column, row, or floating state changes |
| `window-changed` | `window` | a window's title or app name changes |
| `focus-changed` | `window`, `windowID`, `monitorID` | the focused window or display changes; `window` is absent on an empty workspace |

Window IDs stay stable while the window exists; pass one to `focus-window-id`.
Changes within about 30 ms arrive together. The daemon never waits for a
subscriber: one that falls more than 1 MiB behind is disconnected and must
reconnect for a new snapshot. New events and fields may appear within a version;
ignore the ones you don't know.

### Diagnostics

Defi logs command summaries and anomalies to three rotating 10 MiB JSONL files
in `~/Library/Logs/Defi/Diagnostics`. They never contain window titles, document
contents, or typed text.

When chasing an intermittent problem, bind `diagnostic-mark` and press it right
after the problem happens. It records the current status and recent trace
without changing focus, layout, or windows:

```toml
[keys]
"mod-d" = "diagnostic-mark"
```

Defi also records a marker on its own (`kind=marker`, `event=auto`, with a
`reason`) when a command's first write takes over 150 ms, its focus over 500 ms,
or an animation frame gap over 50 ms, at most once per 30 seconds and 20 times
per hour.

## Built-in defaults

These values apply without a config file. Your config should only contain what
you change.

```toml
mod = "ctrl+alt"
show_cheatsheet_on_modifier_hold = true

[layout]
default_column_width = 0.80
preset_column_widths = [0.33, 0.50, 0.66, 0.80]
preset_window_heights = [0.33, 0.50, 0.66]
center_focused_column = "never"
always_center_single_column = false
gaps = 8
reserved_top = 0
reserved_bottom = 0

[input]
focus_follows_mouse = false
focus_follows_mouse_max_scroll_amount = 0.0
focus_follows_mouse_delay_ms = 50
mouse_follows_focus = false
scroll_gestures = false
scroll_gesture_fingers = 2
scroll_gesture_speed = 1.0
scroll_gesture_snap = true

[menu_bar]
enabled = true
workspace_style = "name"

[animation]
enabled = true
stiffness = 800
damping_ratio = 0.9

[overview]
zoom = 0.5
window_previews = true
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

[keys]
# mod: focus
"mod-left" = "focus-column left"         # also mod-h
"mod-right" = "focus-column right"       # also mod-l
"mod-up" = "focus-window up"             # also mod-k
"mod-down" = "focus-window down"         # also mod-j
"mod-home" = "focus-column first"
"mod-end" = "focus-column last"
"mod-i" = "focus-workspace up"           # also mod-pageup
"mod-u" = "focus-workspace down"         # also mod-pagedown
"mod-1" = "focus-workspace-position 1"
# ... through mod-9

# mod-cmd: move
"mod-cmd-left" = "move-column left"      # also mod-cmd-h
"mod-cmd-right" = "move-column right"    # also mod-cmd-l
"mod-cmd-up" = "move-window up"          # also mod-cmd-k
"mod-cmd-down" = "move-window down"      # also mod-cmd-j
"mod-cmd-home" = "move-column first"
"mod-cmd-end" = "move-column last"
"mod-cmd-i" = "move-column-to-workspace up"     # also mod-cmd-pageup
"mod-cmd-u" = "move-column-to-workspace down"   # also mod-cmd-pagedown
"mod-cmd-1" = "move-column-to-workspace-position 1"
# ... through mod-cmd-9

# mod-shift: monitors and workspace order
"mod-shift-left" = "focus-monitor left"  # also mod-shift-h, and up/down/right
"mod-shift-cmd-left" = "move-column-to-monitor left"  # also mod-shift-cmd-h, and up/down/right
"mod-shift-i" = "reorder-workspace up"   # also mod-shift-pageup
"mod-shift-u" = "reorder-workspace down" # also mod-shift-pagedown

"mod-leftbracket" = "consume-or-expel-window left"
"mod-rightbracket" = "consume-or-expel-window right"
"mod-period" = "unjoin-windows"
"mod-semicolon" = "join-window left"
"mod-quote" = "join-window right"
"mod-r" = "cycle-width next"
"mod-minus" = "cycle-width previous"
"mod-equal" = "cycle-width next"
"mod-f" = "maximize-column"
"mod-c" = "center-column"
"mod-v" = "toggle-floating"
"mod-shift-v" = "activate-floating"
"mod-shift-comma" = "focus-floating previous"
"mod-shift-period" = "focus-floating next"
"mod-o" = "toggle-overview"
"mod-tab" = "recent-windows next"
"mod-shift-tab" = "recent-windows previous"
"mod-shift-slash" = "toggle-cheatsheet"

# No rules by default.
```

## Unsupported configuration

Startup commands and window dimming are not implemented. Setting names have no
compatibility aliases before the first stable release: use them exactly as
documented here.
