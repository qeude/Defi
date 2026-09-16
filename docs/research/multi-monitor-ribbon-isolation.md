# Multi-monitor ribbon isolation

Research date: 2026-09-16. This note records constraints considered before implementation; it does not describe an implemented Defi solution.

## Scope

This note records the constraints considered for Defi's horizontal ribbon. It does not establish a reusable cross-application
clipping API for partially visible columns on side-by-side displays.

## Native Spaces and remaining uncertainty

Separate native Spaces can affect native display ownership and rendering, but this research did not establish a public guarantee that a partially visible third-party window stays attached to its intended monitor for every position. Do not infer a reliable 50-percent ownership rule or conclude that the Spaces preference alone fixes this bug. Likewise, source rectangle overlap alone is not proof that every overlapping pixel is actually rendered: native display ownership must be observed in a real desktop test.

No mutating private-API experiment or comparative runtime validation was performed during this research.

## Recommended next decision

The supported alternative worth proposing is a technical vertical display arrangement for Defi's horizontal ribbon, with a saved logical desk arrangement for directional commands and pointer crossing. A staircase can additionally separate vertical parking regions. This preserves actual window content and widths rather than replacing the native window content or hiding the column.

Changing macOS display coordinates also changes unmanaged app placement, native pointer paths when Defi stops, and drag behavior. Before adopting it, decide whether Defi should manage and restore that topology or require a manual arrangement. The user's permission to rearrange temporarily during tests does not authorize leaving a different system arrangement behind.

This fits the current [macOS-authoritative ADR](../adr/0001-keep-macos-authoritative.md) better than captured-motion overlays or new private compositor mutation. Any implementation still needs native validation of pointer crossings, drag behavior, sleep/reconnect, and restoration after daemon exit. No topology change has been implemented by this research.
