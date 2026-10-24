# Stacks within application size constraints

## Sub-features

- Balanced stacks: a column's height is split evenly after gaps. A window's verified minimum or maximum height, read from the window server, can force its own slot; the other windows share what remains.
- Rejected joins: `join-window` fails with `cannot join: stack needs <n>pt but only <m>pt is available` and changes nothing, so membership, focus and scroll all stay as they were.
- Automatic separation: if a stack stops fitting after the monitor shrinks or a constraint changes, the longest top-to-bottom run that fits stays in the column. The other windows move, in order, into new columns directly to its right, and focus stays on the same window. Columns never merge back.
- An oversized single window is placed at its own minimum height, top-aligned and overflowing the viewport, so Defi does not keep retrying a size the app refuses. It is listed in `oversized-stack-windows=` of `defi status` and is never split.

## How to get to it (user POV)

Stack windows with `join-window left|right` (Option+; and Option+' by default) and split them with `unjoin-windows` (Option+R). Separation happens on its own after a display, Dock, reserved-area or app constraint change.

## Driving it with the defi CLI

```sh
python3 script/desktop_lock.py --wait python3 .agents/skills/verify-defi/stacks_check.py
```

The script opens ClampFixture windows with `DEFI_FIXTURE_MIN` on the first empty workspace of the first monitor and shrinks the viewport with `set-reserved-area bottom 400`. Each scenario prints PASS or FAIL. Afterwards it restores the bottom edge, closes its windows, returns to the initial workspace and writes evidence. Pass means every line is PASS and `daemons=1`.

To check one join by hand:

```sh
defi join-window left; echo $?   # non-zero with "cannot join: ..." when it cannot fit
defi status | tr ' ' '\n' | grep -E '^(focused|oversized-stack-windows|drift)='
```

## Gotchas

- Constraints come only from optional private window-server metadata. Without it, stacks stay evenly split and joins are never refused. That is the intended fallback, not a failure.
- The script needs exactly one monitor, because reserved-area commands apply to every monitor. It restores the bottom reserved edge to `--restore-bottom` (default 0). Pass your own value if you reserve a bottom edge at runtime. It never touches the top edge, so a SketchyBar top reservation survives.
- The window server reports a minimum taller than the screen as the window's current height, so an oversized window only appears once the viewport is smaller than the screen (reserved area, Dock, smaller display). The script reproduces it with a 0.9x minimum and a 400pt bottom reservation, and checks from `defi trace` that the coordinator applies no frame writes to that window, which means no resize battle. `sizeWrites` is global and also moves for unrelated windows.
- Real apps with tall minimum heights to try by hand: System Settings, Xcode's Organizer, Simulator.
- The window server reports a minimum no larger than the window's current frame. A window that first appears below its minimum is read with a smaller minimum until a later topology re-read, and separation then catches up. ClampFixture opens at its `DEFI_FIXTURE_MIN` for this reason.
- Defi reads a new window's constraints when discovery adopts it, measured at 0.3 to 0.6 s after the window appears. A join sent before that is accepted, and the stack is then separated once the minimum is known. The script waits for adoption before joining.
- Covering tests: `StackConstraintsTests`, `StackConstraintRuntimeTests`.
