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
An opt-in `overview.experimental_surface_transitions` path may temporarily animate
cached snapshots from observed native frames into the active Overview ribbon.
Samples may be stale while a refresh is pending or has failed.
It uses public one-shot ScreenCaptureKit samples and Defi-owned Core Animation layers, never
native-window scale/opacity mutations. It has explicit pixel-buffer budgets,
no persistent capture sessions, no disk cache, and no frame history. Opening animates
ready surfaces, using the bounded preloaded preview cache for missing surfaces and
lightweight cards when no image exists yet. These fallback layers animate from
verified native geometry and are released at the end of opening so progressive
previews remain visible. Reverse surface animation is limited to unchanged
native geometry and Overview offsets; selection uses the existing native path.
A ribbon experiment that animated these samples in place of native windows was
removed: it rarely engaged and showed a visible crossfade at handoff.
All committed focus and topology changes still pass
through DefiRuntime, preserving the macOS authority established by ADR 0001.
