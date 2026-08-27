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

`nativeWindowTabGroup` finds an `AXTabGroup`, reads its tabs and selected item,
and records the observed titles in
[`SnapshotEngine.swift`](../../Sources/DefiMacOS/SnapshotEngine.swift#L995).

`nativeTabBackingWindowIDsByRepresentative` associates physical windows by
process, role, subrole, title multiset, and frame proximity in
[`WindowDiscoverySupport.swift`](../../Sources/DefiMacOS/WindowDiscoverySupport.swift#L134).
Discovery removes those backing windows from the managed snapshot in
[`MacOSPlatform+WindowSnapshotDiscovery.swift`](../../Sources/DefiMacOS/MacOSPlatform%2BWindowSnapshotDiscovery.swift#L560).

`nativeWindowTabRepresentativeReplacements` forms a unique pair between a
missing representative and a new representative that contains it among its
backing IDs in
[`WindowDiscoverySupport.swift`](../../Sources/DefiMacOS/WindowDiscoverySupport.swift#L109).
`DesktopSnapshot.windowIDReplacements` carries that pair to
`reconcileWindows`, which migrates runtime state before remove and add handling
in [`WindowReconciliation.swift`](../../Sources/DefiRuntime/WindowReconciliation.swift#L164).

The discovery tests cover unique and ambiguous matches. Runtime tests cover
column order, width, scroll, and focus preservation:

- [`WindowDiscoveryTests.swift`](../../Tests/DefiMacOSTests/WindowDiscoveryTests.swift#L1027)
- [`WindowLifecycleTests.swift`](../../Tests/DefiRuntimeTests/WindowLifecycleTests.swift#L161)

## Remaining rule

Use the existing Quartz inventory and `isOnscreen` state as the authoritative
public source for disappearance. Add private WindowServer queries only if a
reproducible case proves that public inventory cannot preserve the identity
invariants.

If broader structural matching becomes necessary, form at most one old-to-new
pair per process and reject ambiguity. Keep the current native-tab membership
path as evidence, not as the foundation of logical identity.
