---
status: accepted
---

# Keep overview behavior independent from capture

Defi builds each monitor's Overview from logical runtime state. Window previews
are optional, enabled through configuration, refreshed once for the current
Overview session, and never required for navigation, focus, or window movement.
The last valid images may remain in a bounded memory-only cache while fresh
captures are pending. They are never persisted.
Missing, stale, protected, or denied previews fall back to identifiable cards.
The Overview may animate as one surface, but captured cards do not simulate the
motion of native windows. All committed focus and topology changes still pass
through DefiRuntime, preserving the macOS authority established by ADR 0001.
