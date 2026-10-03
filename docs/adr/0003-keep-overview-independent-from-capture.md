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
An opt-in `experimental_surface_transitions` path may temporarily animate fresh
captured pixels from observed native frames into the active Overview ribbon.
It uses public one-shot ScreenCaptureKit samples and Defi-owned Core Animation layers, never
native-window scale/opacity mutations. It has explicit pixel-buffer budgets,
no persistent capture sessions, no disk cache, no frame history, and falls back to the ordinary Overview when a
complete fresh set is unavailable. Reverse animation is limited to unchanged
native geometry and Overview offsets; selection uses the existing native path.
This exception tests visual continuity and does not authorize a compositor or
captured replacement for normal ribbon navigation. All committed focus and topology changes still pass
through DefiRuntime, preserving the macOS authority established by ADR 0001.
