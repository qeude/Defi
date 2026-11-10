# Window identity

A managed window is a logical node whose WindowServer ID and Accessibility
element may change. Some applications replace the top-level window ID when a
native tab is opened or selected. Discovery pairs a managed window that left, or
that a new tab replaced, with a new window at the same frame in the same process and reports the pair in
`DesktopSnapshot.windowIDReplacements`. `reconcileWindows` moves focus, width,
scroll, targets, and pending commits to the new ID before any removal or
addition, so the column neither moves nor animates. A pair applies only when it
is unique; anything ambiguous is an ordinary removal and addition, and a new
window from the same app stays a new column. Titles are metadata, never
identity.

## Native tabs

AppKit lists only the selected tab in Accessibility. Inactive tabs stay in the
WindowServer inventory, ordered out at the group's frame, so transitions are
decided from WindowServer state. A tab switch, or closing the visible tab, posts
only `kAXMainWindowChangedNotification`, and both Accessibility and WindowServer
may still show the old tab at that moment. A process with tab groups is
therefore reread briefly after each of its events, and for at most a second
while a group stays unsettled. When frames tie, Quartz matching prefers the
on-screen record, so a new window never takes a hidden tab's ID.
