# Defi context

Defi arranges native macOS windows as scrolling columns while preserving macOS
as the owner of window lifecycle and focus.

## Layout

**Monitor**:
Defi's logical representation of one connected macOS display. Each monitor owns
an independent ordered stack of workspaces.
_Avoid_: Screen, output

**Workspace**:
A globally unique virtual collection of windows owned by exactly one monitor at
a time. A workspace is either ordinary or named and may move between monitors.
_Avoid_: macOS Space, desktop

**Ordinary workspace**:
A dynamic workspace without a stable name. Each monitor keeps one empty ordinary
workspace at the bottom, and removes other ordinary workspaces after they become
empty and inactive.
_Avoid_: Numbered workspace, anonymous workspace

**Named workspace**:
A persistent workspace with a stable name that application rules and commands
can target, including while it is empty. Configuration supplies its name and
optional monitor affinity; otherwise it starts on the primary monitor.
_Avoid_: Numbered workspace, static workspace

**Trailing workspace**:
The system-owned empty ordinary workspace at the bottom of each monitor's stack.
It may be active while empty; once populated, it becomes ordinary and is
immediately replaced.
_Avoid_: Default workspace, numbered workspace

**Workspace position**:
The current one-based position of a workspace in its monitor's ordered stack. It
may change when workspaces are inserted, removed, reordered, or moved; a
position beyond the current stack resolves to the trailing workspace.
_Avoid_: Workspace number, workspace ID

**Workspace affinity**:
The monitor a workspace returns to after a temporary monitor disconnection.
Explicit monitor moves change it, while automatic migration or an unavailable
configured monitor leaves it pending as the workspace lives elsewhere.
_Avoid_: Current monitor, original monitor

**Placement preference**:
The last existing workspace associated with an application when no application
rule provides a named destination. It never recreates a removed workspace.
_Avoid_: Application rule

**Workspace topology**:
The workspace identities, monitor ownership, vertical order, window membership,
column structure, focus, widths, and scroll state that Defi preserves across
daemon restarts within a macOS session.
_Avoid_: Layout, configuration

**Scrolling strip**:
The continuous horizontal sequence of columns inside a workspace.
_Avoid_: Grid, tree

**Column**:
An ordered unit in the scrolling strip containing one tiled window or a vertical
stack of tiled windows.
_Avoid_: Tile, pane

**Stack**:
The ordered vertical group of tiled windows inside one column.
_Avoid_: Column

**Managed window**:
A native application window whose placement and focus belong to Defi's model.

**Tiled window**:
A managed window that belongs to a column and participates in the scrolling
layout.

**Floating window**:
A managed window that belongs to a workspace without participating in its
scrolling layout.

**Transient window**:
A dialog, sheet, or modal window whose monitor and workspace follow its owning
window and which cannot be managed independently from that owner.

**Parking**:
The offscreen placement of windows from inactive workspaces without hiding or
minimizing them.
_Avoid_: Hiding, minimizing

**Overview**:
An interactive stack of full-width workspace ribbons. Each ribbon shows a
uniformly scaled view of its scrolling strip and exposes normal navigation and
window movement.

**Overview viewport**:
The temporary two-axis view into an Overview. Moving it does not change native
window frames or a workspace's scrolling offset.
_Avoid_: Workspace scroll offset

**Window preview**:
A non-authoritative captured image of a managed window shown in the Overview.
Its absence or staleness never changes Overview behavior.
_Avoid_: Live window, window mirror, screenshot

## Focus and responsiveness

**Human focus intent**:
The latest direct keyboard, pointer, Dock, or Command-Tab action that identifies
the window the user intends to interact with.
_Avoid_: Focus notification

**Confirmed native focus**:
A macOS focus observation for which the frontmost application and focused window
agree. A single delayed Accessibility notification is not confirmed focus.

**Latency-sensitive application**:
An application that cannot reliably apply intermediate window frames within the
active display's refresh budget.
_Avoid_: Slow-app special case
