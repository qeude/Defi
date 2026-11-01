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
the real windows moving under the overlay: the replica drops as few frames
translucent as opaque, and moving the windows costs frames whenever it happens.
Delaying the moves (25 ms, or to the end of the
spring), an opaque overlay (always, or only during bursts) and keeping border
windows shown were each neutral or worse.

## Decision to make

Constant 120 Hz motion needs the windows below the overlay to stop costing the
compositor for the duration of a motion, without their apps seeing an
occlusion. The candidates:

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
in 16 navigations, against 4-5 today). Neither candidate is open today, and the
second would not help: neither focus changes nor an opaque backdrop made the
replica's windows occluded, and its overlay costs as little translucent.

`script/fluidity_probe.py` counts hitches per user action. Over 36 column navigations,
skipping every native position write gave 51 hitches against 98 (two runs each), most in
the first 100 ms and after 300 ms; the middle of the spring is nearly clean. Native moves
are therefore about half of the cost, and the rest belongs to the start and the landing.
Deferring landing captures by 700 ms did not help (98 against 82, two runs each). Keeping the
overlay's layers alive at zero opacity between motions did not help either (88 against 83). Deferring
focus writes past the motion moved its hitches later without a clear gain (41 against 44 to
66), from a single valid run.

Three more passes per variant, on the built-in 120 Hz display (M1 Pro), measured against
five control runs of 175 to 232 hitches in total. None left that noise, on any action:
starting the springs 8 or 16 ms after the commit (186, 230), spacing native writes by 16 ms
(224), dropping layers off screen on one side for the whole motion (215, 179), writing
parked windows 220 ms later (180), stopping the border settle loop after landing (208), and
removing the Overview's closing glass fade with a layer-driven cheatsheet fade (212).
Instruments labels about a third of Defi's hitches "potentially expensive app update", few
"expensive render", and gives the rest no cause. Controls vary as much per action (column
1.6 to 3.8 hitches per event), so single runs cannot judge a change. Zero hitches was not
reached on any overlay motion: what remains below the overlay is the compositor and the
apps, and no public API or tested private call removes them.

Until it is accepted, Defi keeps the translucent overlay and the measured limit
above.
