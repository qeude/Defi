---
status: accepted
---

# Keep overview behavior independent from capture

Defi builds each monitor's Overview from logical runtime state. Window previews
are enabled by default, refreshed once for the current Overview session, and
never required for navigation, focus, or window movement. Defi requests Screen
Recording once, before presenting the Overview so the system prompt is not
covered. The last valid images may remain in a bounded memory-only cache while
fresh captures are pending. They are never persisted.

Missing, stale, protected, or denied previews degrade to identifiable cards
without errors or repeated prompts; `overview.window_previews = false` opts out.

Opening and closing the Overview zoom the real windows to their cards and back.
This does not depend on previews. It uses Defi-owned Core Animation layers, never
native-window scale/opacity mutations. Ready one-shot ScreenCaptureKit samples
are used when available, then the bounded preview cache, then lightweight cards;
all animate from verified native geometry. Fallback layers are released at the
end of opening so progressive previews remain visible. Reverse animation is
limited to unchanged native geometry and Overview offsets. There are explicit
pixel-buffer budgets, no persistent capture sessions, no disk cache, and no frame
history. A ribbon experiment that animated these samples in place of native
windows was removed: it rarely engaged and showed a visible crossfade at handoff.
All committed focus and topology changes still pass through DefiRuntime,
preserving the macOS authority established by ADR 0001.
