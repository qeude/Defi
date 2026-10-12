# Scrolling column navigation

## Sub-features

- Focus left/right/first/last column.
- Move column, cycle and maximize width.
- Speculative, latest-wins animation with position-only writes.

## How to get to it (user POV)

Configured hotkeys, or the CLI.

## Driving it with the defi CLI

```sh
defi status > before.status
for i in 1 2 3; do defi focus-column right; done; defi focus-column left
sleep 1; defi status > after.status; defi trace > trace.log
```

Pass: `focused=` changes as expected, `animating=false`, `drift=0[]`, `droppedFrames=0`, `focusPending=false`. In `trace.log` no repeated corrections or rollbacks after the last command.

## Gotchas

- With one column on the workspace nothing moves; check `list-workspaces --json` window counts first.
- Slow apps (`slowAppDetails`) legitimately settle later. Wait for `axPending=false`.
- Visual smoothness needs Computer Use with human-paced input, not a tight loop.
- Covering tests: `testHorizontalAnimationFrameWritesPositionWithoutSize`, `testRapidNativeFocusKeepsLatestIntent`.
