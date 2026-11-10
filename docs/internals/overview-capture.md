# Overview capture

Defi builds each monitor's Overview from logical runtime state. Window previews
are on by default, refreshed once per Overview session, and never required for
navigation, focus, or window movement. All committed focus and topology changes
still pass through `DefiRuntime` (see [macOS authority](./macos-authority.md)).

## Permission

Screen Recording is requested once Accessibility is granted, and again before
the first Overview of a session if still missing, before the Overview appears so
the system prompt is not covered. Missing, stale, protected, or denied previews
degrade to identifiable cards without errors or repeated prompts;
`overview.window_previews = false` opts out.

## Capture

Pictures come from the WindowServer window capture and fall back to
ScreenCaptureKit, which lights the menu bar recording indicator. The last valid
images may stay in a bounded memory-only cache while fresh captures are
pending. There are explicit pixel-buffer budgets, no persistent capture
sessions, no disk cache, and no frame history. Persistent per-window streams
kept the capture badge on captured windows and disrupted ribbon motion, so every
capture is one-shot.

When another app shares a whole display, it shares the Overview and ribbon
overlay too, so other workspaces' windows can appear in the share.
`NSWindow.sharingType = .none` cannot guarantee exclusion, because the capturing
app controls its own filter.

## Zoom

Opening and closing the Overview zoom the real windows to their cards and back.
The zoom does not depend on previews: it uses Defi-owned Core Animation layers,
never native-window scale or opacity changes, and draws from a ready capture,
then the bounded preview cache, then lightweight cards, all from verified native
geometry. Fallback layers are released at the end of opening so progressive
previews remain visible. Reverse animation is limited to unchanged native
geometry and Overview offsets.

The same captures feed the [ribbon overlay](./ribbon-motion.md) outside the
Overview.
