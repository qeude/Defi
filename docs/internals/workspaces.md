# Workspaces

Workspaces are globally unique and owned by one monitor at a time, instead of a
configured copy of each workspace on every monitor. This matches Niri's
workspace model while keeping Defi's per-monitor active workspace and scrolling
strip.

## Lifecycle

Ordinary workspaces are dynamic: every monitor keeps one trailing empty
workspace, populated trailing workspaces become ordinary, and empty inactive
ordinary workspaces disappear. Named workspaces persist, are the only valid
application-rule destinations, and stay directly addressable whatever their
position.

`workspaces.names` declares only persistent named workspaces, with optional
default and monitor affinity. Built-in defaults declare none. Removing a
configured name converts an occupied workspace to ordinary and drops it only
when empty. Renaming at runtime is not supported.

## Monitors

Each workspace has a monitor affinity distinct from its current owner. Display
loss temporarily migrates affected workspaces, and a confident reconnection
returns them; explicit monitor moves update affinity, while ambiguous matches
leave workspaces on the fallback monitor. Defi preserves the full workspace
topology across daemon restarts within one macOS session, then rebuilds named
workspaces from configuration for a new session.

## Navigation

Positions are one-based, non-wrapping, and resolve past the current stack to the
trailing workspace. Vertical transitions use public Accessibility position
writes and animate only when the whole transition is safe and refresh-budget
compliant; otherwise every participating window switches at once.

The empty trailing workspace is focusable without a Defi-owned focus sink. macOS
may therefore keep sending ordinary keys to the previously focused parked
application until a new native focus intent occurs.

## Pinned columns

A pinned column stays in `Workspace.columns`, flagged with `Column.pin`, at
index 0 for the left edge and last for the right, so membership, removal,
persistence, parking, and window moves need no second path. It belongs to the
monitor, though: `maintainWorkspaceLifecycle` carries it into whichever
workspace is active, and a workspace holding nothing else still counts as empty
for the lifecycle. Since it is the same window in the same frame before and
after a switch, the vertical motion leaves it still with no special case.
Moving the active workspace to another monitor must take it out first.

One pin per monitor keeps a single inner edge: `clearingPinnedEdge` moves every
scroll target so no column rests across it, because a window there would cover
the pinned column (macOS cannot clip windows) or, parked, leave a hole. With two
pins both edges would need clearing at once, which generally leaves gaps.
Layout and scrolling give the pinned column no width in the strip and narrow
the viewport by its width, so scroll offsets count in the scrolling strip beside
it. Every fraction still counts in the whole strip, the pinned column's capped at
`maximumPinnedColumnFraction` and the others' at the room it leaves: pinning,
unpinning, or carrying the pin to another workspace then moves windows without
resizing them, so no width write lands on a window whose picture the overlay is
sliding in. During motion the overlay
draws it above the strip, so columns slide beneath it as in a compositor.
`ScrollFocus.pinned` is unrelated: it records `center-column`.
