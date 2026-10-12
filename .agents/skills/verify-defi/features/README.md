# Defi feature map

Maintained verification source for `verify-defi`. One file per user-facing feature.

| Feature | File | Primary proof |
| --- | --- | --- |
| Overview with window previews | [overview.md](overview.md) | `overviewReceivedPreviews > 0` and visible captures |
| Scrolling column navigation | [scrolling-navigation.md](scrolling-navigation.md) | focus and scroll converge, no rollback in trace |
| Virtual workspaces and parking | [workspaces.md](workspaces.md) | active workspace changes, inactive windows parked |
| Service lifecycle and single instance | [service-lifecycle.md](service-lifecycle.md) | restart keeps one daemon and the session store |
