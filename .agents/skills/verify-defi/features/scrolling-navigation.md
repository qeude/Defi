# Scrolling column navigation

## Sub-features

- Focus left/right/first/last column.
- Move column, cycle and maximize width.
- Speculative, latest-wins animation with position-only writes.
- Focused column centering: `center_focused_column` `never`, `always`, `on-overflow`.

## How to get to it (user POV)

Configured hotkeys, or the CLI. Centering mode: Settings > Layout > Focused
column, or `center_focused_column` under `[layout]` in the config file.

## Driving it with the defi CLI

```sh
defi status > before.status
for i in 1 2 3; do defi focus-column right; done; defi focus-column left
sleep 1; defi status > after.status; defi trace > trace.log
```

Pass: `focused=` changes as expected, `animating=false`, `drift=0[]`, `droppedFrames=0`, `focusPending=false`. In `trace.log` no repeated corrections or rollbacks after the last command.

## Journey: focused column centering

```sh
python3 script/desktop_lock.py --wait .agents/skills/verify-defi/centering_check.sh
```

The script opens four scratch TextEdit documents on the trailing empty
workspace, focuses the first column, steps right once per mode, and classifies
where the focused window landed. It restores the config, closes the documents
and returns to the initial workspace.

| Column width | `never` | `always` | `on-overflow` |
| --- | --- | --- | --- |
| 0.50 (two columns fit exactly) | right-edge | centered | right-edge |
| 0.66 (two columns overflow) | right-edge | centered | centered |

Pass: every row prints `PASS`, `drift=0[]`, initial workspace and config
restored, `daemons: 1`. Run it again with `DRIVE=hotkeys` to send the default
`hyper-leftbracket` and `hyper-right` key events at human pace; it also requires
the daemon's `captured=` counter to rise. Check visual smoothness with Computer
Use when available.

## Gotchas

- With one column on the workspace nothing moves; check `list-workspaces --json` window counts first.
- Slow apps (`slowAppDetails`) legitimately settle later. Wait for `axPending=false`.
- Visual smoothness needs Computer Use with human-paced input, not a tight loop.
- Covering tests: `testHorizontalAnimationFrameWritesPositionWithoutSize`, `testRapidNativeFocusKeepsLatestIntent`.
- Centering needs one monitor and TextEdit not running; the script refuses otherwise.
- On-overflow decides when the selected window changes. A width change or
  column move afterwards keeps that decision; it is not a second focus change.
- Pure centering tests: `WorkspaceScrollingTests`, `NativeFocusTests/onOverflowDecisionHoldsUntilSelectionChanges`.
