# Defi context

Defi arranges native macOS windows as scrolling columns while preserving macOS
as the owner of window lifecycle and focus.

## Layout

**Monitor**:
Defi's logical representation of one connected macOS display. Each monitor owns
an independent copy of the configured workspaces.
_Avoid_: Screen, output

**Workspace**:
A named virtual collection of windows owned by exactly one monitor. Workspaces
with the same name on different monitors are distinct.
_Avoid_: macOS Space, desktop

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
