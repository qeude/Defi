# Native tab window identity

Research completed on August 25, 2026 using Defi's implementation, observed
macOS behavior, and Apple's Accessibility documentation.

## Problem

Some applications replace a top-level WindowServer ID when the user opens or
selects a native tab. If Defi treats that transition as one window disappearing
and another appearing, the runtime can move the column, change its width, shift
the viewport, or lose focus.

The correct model is a stable logical managed window whose physical
`WindowID` and `AXUIElement` may change. A native tab transition should rebind
that logical window in place before ordinary remove and add processing.

## Identity model

Keep these identities separate:

- the logical managed window stored by the layout;
- the current WindowServer ID used for Quartz inventory and frame operations;
- the current Accessibility element used for reads, writes, and focus.

Rebinding replaces the physical identifiers without replacing the logical
layout node. Titles remain metadata and must not define identity because tab
titles change and can collide.

## Detecting a replacement

A replacement candidate must belong to the same process as the old window. The
old ID must have disappeared from the authoritative visible-window inventory or
have a pending destruction event. Compare structural facts such as bundle,
workspace, role, subrole, WindowServer level, parent, and frame.

Apply a replacement only when the match is unique. If multiple old or new
windows fit, process the events as ordinary removals and additions. A new visible
window from the same application must remain a new column.

Creation and destruction can arrive in either order. Correlate the short event
burst, commit a unique compatible pair, and fall back to normal processing when
the burst is ambiguous. While the rebind waits for Accessibility confirmation,
rescans must not admit the target as a second logical window.

## Rebind invariants

Before remove and add processing, migrate every reference to the old physical
ID:

- the runtime window entry and its column position;
- focus and pending focus work;
- learned width, scroll position, and target frames;
- pending frame commits and discovery state;
- native-tab backing membership.

The next frame write must target the new physical window. A completed rebind
must not start a scroll animation or change column order.

## Accessibility tab groups

`kAXTabsAttribute` and `kAXTabGroupRole` expose the tab control's Accessibility
objects. Apple does not promise a stable mapping from those objects to an
`AXWindow` or `CGWindowID`.

- [`kAXTabsAttribute`](https://developer.apple.com/documentation/applicationservices/kaxtabsattribute)
- [`kAXTabGroupRole`](https://developer.apple.com/documentation/applicationservices/kaxtabgrouprole)

Defi can use an `AXTabGroup` as evidence that windows belong together and to
exclude inactive backing windows. It should not derive persistent window
identity from tab titles or assume the selected tab keeps one WindowServer ID.

## Current Defi path

AppKit lists only the selected tab in Accessibility. Inactive tabs stay in the
WindowServer inventory, ordered out at the group's frame. Defi therefore keeps,
per visible member, the IDs of its ordered-out members, and decides transitions
from WindowServer state, never from titles.

`nativeWindowHasTabs` reads the `AXTabGroup` of a newly discovered window in
[`SnapshotEngine.swift`](../../Sources/DefiMacOS/SnapshotEngine.swift).
`nativeTabTransition` pairs, per process, a managed window that was ordered
out or destroyed with a new on-screen window at the same frame, when the new
window shows tabs or is a known hidden member, and only when the pair is unique.
Its transition table lives with the code in
[`WindowDiscoverySupport.swift`](../../Sources/DefiMacOS/WindowDiscoverySupport.swift).
Discovery drops the departed and hidden members from the snapshot and emits the
pair as `DesktopSnapshot.windowIDReplacements`; `reconcileWindows` migrates
runtime state before remove and add handling in
[`WindowReconciliation.swift`](../../Sources/DefiRuntime/WindowReconciliation.swift).

A tab switch or the close of the visible tab posts only
`kAXMainWindowChangedNotification`, so Defi observes it alongside the focused
window. The Accessibility list and WindowServer can both still show the old tab
when that event arrives; Defi rereads a process with tab groups briefly after
each of its events, and for at most a second while a group stays unsettled.

When WindowServer records tie on frame, Quartz matching prefers the on-screen
record, so a new window never borrows a hidden tab's ID.

`script/native_tab_probe.py` drives a fixture through new tab, switch, close
visible, close hidden, and a same-title new window, and reports the column
count, neighbour movement, and overlay presentations per step.

## Remaining rule

Use the existing Quartz inventory and `isOnscreen` state as the authoritative
public source for disappearance. Add private WindowServer queries only if a
reproducible case proves that public inventory cannot preserve the identity
invariants.

If broader structural matching becomes necessary, form at most one old-to-new
pair per process and reject ambiguity. Keep the current native-tab membership
path as evidence, not as the foundation of logical identity.
