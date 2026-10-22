# Single-window native drag

## Sub-features

- Dragging a tiled window by its title bar moves only that window, never its whole column.
- While the button is held, the proxy overlay lays the other windows out as the drop would and marks the carried window's slot. Column membership does not change until release.
- Release commits once to the previewed target: extraction from a stack (the rest of the stack keeps its order and rebalances), moving a single column across neighbors, stacking into the column under the pointer, or insertion on another monitor's active workspace.
- Releasing over the window's own column, or dragging out and back to the origin, changes nothing; the window returns to its slot.
- The middle half of another column stacks the window into it. Its outer quarters and the gaps target the gap between columns.
- Over its own stacked column, the native drop path reorders rows. Off every display, it decides as before.
- Not in this slice: edge scrolling to offscreen columns (#97).

## How to get to it (user POV)

Grab the title bar of any tiled window and drag it sideways into the outer quarter of a neighboring column. The other windows slide apart on the overlay; let go to drop. Floating windows move freely as before and never show a preview.

## Driving it with cliclick and fixture windows

```sh
python3 script/desktop_lock.py --wait python3 .agents/skills/verify-defi/drag_check.py
```

It opens three fixture windows on an empty workspace, narrows each with `cycle-width previous` so all three columns are fully on screen (it aborts otherwise), stacks the first two with `join-window`, then performs four human-paced title-bar drags aimed at neighboring column centers with `cliclick` (30 moves at about 20 ms each, a 350 ms hold before release). Each line reports column membership before, while held, and after release, plus the drop target the overlay previewed while held. It closes the fixtures, returns to the initial workspace, and prints the daemon count.

Pass: every line `PASS`, `held=` equals `before=` (no mutation during the drag), a previewed target is present for the two real moves (the no-op cases may preview the unchanged layout), script exit 0, `daemons=1`. Evidence lands in `dist/verification/evidence-<timestamp>/` (`results.json`, `trace-<case>.log`, `before.status`, `after.status`).

The script requires exactly one monitor and exits otherwise. Drive cross-monitor drops by hand: drag a window's title bar onto the other display between two columns, then check `list-workspaces --json` window counts and `defi status` `focused=`.

## Gotchas

- Keep the pointer away from the display edges. A drag that reaches an edge triggers macOS's own window tiling (`WindowManager` windows in the trace), which rearranges windows and can make discovery reclassify unrelated windows as floating. The script clamps targets 80 pt inside the display; edge behavior during a drag belongs to #97.
- Needs Accessibility for the terminal that runs `cliclick`; without it the events are dropped and every case fails with `held == before == after`.
- The daemon traces each preview change as `mouse-drop-preview window=<id> target=<target>` (or `target=none`). The script reads the latest one. Judge the overlay motion and borders by eye.
- Membership comes from `~/Library/Application Support/Defi/workspace-topology.json`, which the daemon rewrites after each sync; the script polls it until it converges.
- The target follows the pointer, not the window: macOS can stop a window from following the pointer off screen. While the pointer stays over the source column the drag is a no-op by design.
- The overlay carries a window only with one monitor. With several monitors the native window follows the pointer, there is no preview, and the drop still commits on release.
- With `animation.window_proxies = false` the older live reorder runs instead: columns move while the button is held.
- Covering unit tests: `MouseReorderingTests` (target selection, stacking, hysteresis, commit, invalidation).
