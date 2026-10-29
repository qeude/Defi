---
status: proposed
---

# Hide moving windows from the compositor during ribbon motion

The ribbon overlay draws every motion from window pictures, and the real windows
move once, through public Accessibility, underneath it. The overlay stays at an
alpha just below 1 so that macOS never reports the windows below as occluded:
an opaque overlay made Chromium, Safari and Electron windows pause and resume
drawing at every step.

Measured on a 5K 120 Hz display (M1 Pro), a replica of the overlay alone drops
about 0.4 frames per motion, while Defi drops about 3.5. The difference is
WindowServer compositing the real windows under the translucent overlay while
Accessibility moves them. Delaying the moves (25 ms, or to the end of the
spring), an opaque overlay (always, or only during bursts) and keeping border
windows shown were each neutral or worse.

## Decision to make

Constant 120 Hz motion needs the windows below the overlay to stop costing the
compositor for the duration of a motion, without their apps seeing an
occlusion. The candidates, none of them allowed by ADR 0001 today:

- Move the windows off the compositor's path during the motion, for example by
  parking every moving window before the motion and placing it once at the
  landing. Public Accessibility only; costs two writes per window and a visible
  risk if an app applies a write late.
- An opaque overlay that keeps the windows below reported as visible, which
  needs a private WindowServer occlusion or window-tag API on Defi-owned
  surfaces. Read-only for third-party windows, but not metadata.

The first was prototyped (park at motion start, place 140 ms later): 99 dropped
frames against 82 over 24 navigations, the second write adding its own. The
second was probed with an empty `SLSSetWindowOpaqueShape` on the overlay: the call
succeeds, but the windows below still flip to occluded at every step (21-27 changes
in 16 navigations, against 4-5 today). Neither candidate is open today.

Until it is accepted, Defi keeps the translucent overlay and the measured limit
above.
