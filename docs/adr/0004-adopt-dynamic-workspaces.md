---
status: accepted
---

# Adopt globally unique dynamic workspaces

Defi replaces the configured workspace copies on every monitor with globally
unique workspaces owned by one monitor at a time. Ordinary workspaces are
dynamic: every monitor keeps one trailing empty workspace, populated trailing
workspaces become ordinary, and empty inactive ordinary workspaces disappear.
Named workspaces persist, are the only valid application-rule destinations, and
remain directly addressable regardless of their current position. This matches
Niri's workspace model while retaining Defi's per-monitor active workspace and
scrolling strip.

Each workspace has monitor affinity distinct from its current owner. Display
loss temporarily migrates affected workspaces, and a confident reconnection
returns them; explicit monitor moves update affinity, while ambiguous matches
leave workspaces on the fallback monitor. Defi preserves the full workspace
topology across daemon restarts within one macOS session, then rebuilds named
workspaces from configuration for a new session.

Positions are one-based, non-wrapping, and resolve past the current stack to the
trailing workspace. Vertical workspace transitions use public Accessibility
position writes and animate only when the whole transition is safe and
refresh-budget compliant; otherwise every participating window switches
immediately. The empty trailing workspace remains focusable without a Defi-owned
focus sink, accepting that macOS may keep sending ordinary keys to the previously
focused parked application until a new native focus intent occurs.

The TOML `workspaces.names` list now declares only persistent named workspaces,
with optional default and monitor affinity. Built-in defaults declare none.
Removing a configured name converts an occupied workspace to ordinary and drops
it only when empty. Runtime naming is deferred.
