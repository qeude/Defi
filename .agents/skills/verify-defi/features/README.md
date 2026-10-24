# Defi feature map

Maintained verification source for `verify-defi`. One file per user-facing feature.

| Feature | File | Primary proof |
| --- | --- | --- |
| Overview with window previews | [overview.md](overview.md) | `overviewReceivedPreviews > 0` and visible captures |
| Scrolling column navigation | [scrolling-navigation.md](scrolling-navigation.md) | focus and scroll converge, no rollback in trace; `centering_check.sh` all PASS |
| Virtual workspaces and parking | [workspaces.md](workspaces.md) | active workspace changes, inactive windows parked |
| Service lifecycle and single instance | [service-lifecycle.md](service-lifecycle.md) | restart keeps one daemon and the session store |
| Width change animation (maximize, cycle, shrink) | [width-animation.md](width-animation.md) | `resize_check.sh`: every change ANIMATED, no jump, drift=0 |
| Native column resizing (edge drag) | [column-resizing.md](column-resizing.md) | real drag sets `columnWidth=pixels:`, neighbor reflows, width survives navigation |
| Single-window native drag with overlay preview | [window-drag.md](window-drag.md) | `drag_check.py`: every case PASS, membership unchanged while held |
