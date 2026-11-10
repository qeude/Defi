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
