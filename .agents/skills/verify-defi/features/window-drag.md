# Single-window native drag

## Sub-features

- Dragging a tiled window by its title bar moves only that window, never its whole column.
- As the drag starts, the other windows close up the carried window's place once; while the button is held nothing else moves and a translucent band marks the drop. Column membership does not change until release, which moves everything once.
- Release commits once to the previewed target: extraction from a stack (the rest of the stack keeps its order and rebalances), moving a single column across neighbors, stacking into the column under the pointer, or insertion on another monitor's active workspace.
- Releasing over the window's own column, or dragging out and back to the origin, changes nothing; the window returns to its slot.
- The closest edge to the pointer wins: a gap between columns opens a new column, a border between two windows of the column under the pointer (or its bottom) stacks there. Another column's top counts only once the pointer enters the menu bar above it or reaches the screen's top edge; in its own stack the top counts like any border.
- The target follows the pointer every frame, with an 8 pt hysteresis on boundaries; release commits the shown one.
- A stack the window's minimum heights cannot fit gets a red outline over the column and opens no slot; releasing there changes nothing.
- Over its own stacked column, the preview shows the row under the pointer, among the other windows, and release commits it. Off every display, the native drop path decides as before.
- Holding the window at a side edge scrolls the strip to offscreen columns (#97).

## How to get to it (user POV)

Grab the title bar of any tiled window and drag it toward the gap between two columns. The others close up once, a band marks the gap, and nothing else moves until you let go.

## Driving it with cliclick and fixture windows

```sh
script/desktop_lock.sh --wait python3 .agents/skills/verify-defi/drag_check.py
```

It opens three fixture windows on an empty workspace, narrows each with `cycle-width previous` so all three columns are fully on screen (it aborts otherwise), stacks the first two with `join-window`, then performs four human-paced title-bar drags aimed at neighboring column centers with `cliclick` (30 moves at about 20 ms each, a 350 ms hold before release). Each line reports column membership before, while held, and after release, plus the drop target the overlay previewed while held. It then adds two more windows and drags into and out of stacks of two, three and four windows, including a row change inside a stack, then drags between two minimum-height windows that cannot share a column. It closes the fixtures, returns to the initial workspace, and prints the daemon count.

Pass: every line `PASS`, `held=` equals `before=` (no mutation during the drag), a previewed target is present for the real moves and `rejectedStack` for the constrained drag (the no-op cases may preview the unchanged layout), script exit 0, `daemons=1`. Evidence lands in `dist/verification/evidence-<timestamp>/` (`results.json`, `trace-<case>.log`, `held-<case>.png`, `before.status`, `after.status`).

Screenshots include the overlay. The script requires exactly one monitor and exits otherwise. Drive cross-monitor drops by hand: drag a window's title bar onto the other display between two columns, then check `list-workspaces --json` window counts and `defi status` `focused=`.

## Gotchas

- Keep the pointer away from the display edges. A drag that reaches an edge triggers macOS's own window tiling (`WindowManager` windows in the trace), which rearranges windows and can make discovery reclassify unrelated windows as floating. The script clamps targets 80 pt inside the display; edge behavior during a drag belongs to #97.
- Needs Accessibility for the terminal that runs `cliclick`; without it the events are dropped and every case fails with `held == before == after`.
- The daemon traces each preview change as `mouse-drop-preview window=<id> target=<target>` (or `target=none`). The script reads the latest one. Judge the overlay motion and borders by eye.
- Membership comes from `~/Library/Application Support/Defi/workspace-topology.json`, which the daemon rewrites after each sync; the script polls it until it converges.
- The target follows the pointer, not the window: macOS can stop a window from following the pointer off screen. While the pointer stays over the source column the drag is a no-op by design.
- Over another display, that display's overlay goes up too: its ribbon makes room, it shows the slot, and a copy of the carried window follows the pointer there. The source display closes the gap. The daemon traces `host id=<id>` in the `ribbon-proxy` log category when it starts.
- With `animation.enabled = false`, Reduce Motion, or without Screen Recording, there is no overlay: the native window follows the pointer and the drop still commits on release.
- Covering unit tests: `MouseReorderingTests` (target selection, stacking, hysteresis, commit, invalidation).
