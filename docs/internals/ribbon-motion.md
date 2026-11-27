# Ribbon motion

The ribbon overlay is the only motion system, on every display. It draws each
motion from window pictures, and the real windows move once, through public
Accessibility, underneath it.

## Translucent overlay

The overlay stays at an alpha just below 1 so macOS never reports the windows
below as occluded: an opaque overlay made Chromium, Safari, and Electron windows
pause and resume drawing at every step. An empty `SLSSetWindowOpaqueShape` on the
overlay did not help; the windows below still flipped to occluded at every step.

## Measured limit

Zero hitches is not reached on any overlay motion, and no public API or tested
private call removes the rest. On a 5K 120 Hz display (M1 Pro), a replica of the
overlay alone drops about 0.4 frames per motion; Defi drops about 3.5. The
difference is the real windows moving under the overlay, translucent or opaque.
`script/fluidity_probe.py` shows native moves account for about half the
hitches, mostly in the first 100 ms and after 300 ms; the rest belongs to the
start and the landing. Instruments labels about a third "potentially expensive
app update", few "expensive render", and gives the rest no cause.

Controls vary from 1.6 to 3.8 hitches per column navigation, so a single run
cannot judge a change: compare several runs of each variant against several
controls. The probe now also judges cadence: the share of render gaps of at most
10 ms inside each `motion` signpost, and the worst gap. Base runs drift more
between runs than within one, so a gain counts only when every trial lies beyond
every pooled base trial (`script/fluidity_report.py`).

## Lead before a motion from rest

The compositor drops frames in the first 50 ms after the commit, while the
native windows move under the overlay; delaying the focus write or the cursor
warp does not change that. A motion from rest starts two frames after its
commit, so its pictures and layers reach the compositor first.

Inside column moves, counted from the moment the motion starts (the `ribbon`
signpost begins at the commit, so the probe also counts the still lead as one
late gap):

| Display | Two frames | A thirtieth of a second |
| --- | --- | --- |
| Fixed 120 Hz external (8 trials each) | 95.7-99.5 % on time, 0.6 late frames per move | 97.5-100 %, 0.3 |
| MacBook Pro built-in, adaptive refresh | about 92 %, half the moves open late | about 96 %, one move in thirty opens late |

The longer lead did not ship. On the built-in display the compositor then ran
some column moves whole at 80 Hz (12 ms gaps), in 6 of 28 trials against none in
20 with two frames; asking for the display's own rate as the minimum, or
animating a one-point layer through the lead, did not prevent it. On the fixed
display it never did (16 trials), but the gain stays inside the spread between
trials and costs 16.7 ms before every motion. `NSScreen.minimumRefreshInterval`
equals `maximumRefreshInterval` on a fixed-rate display, should a per-display
lead be tried again.

The cheatsheet's closing fade also leads by two frames. Its opening fade has no
lead: two frames made it worse on the adaptive display, and 60 ms on the fixed
one only moved its late frames (12-15 per eight openings against 9-13).

An AppKit cheatsheet (one view drawing every shortcut inside an
`NSGlassEffectView`) looked the same and opened at best slightly better than the
SwiftUI one: 7 to 13 late frames per eight openings against 10 to 17, ranges
that overlap, so SwiftUI stays. What costs is the glass and the tint over it:
an empty glass panel loses 4 to 6, the SwiftUI panel without glass as few.
Flattening the content (`drawingGroup`) or wrapping it in the AppKit glass
gained nothing.

The Overview's keyboard zoom waits for its panel. On a 5K fixed 120 Hz display
the compositor shows the first 60 ms after the panel appears in three frames
(gaps of 25 to 70 ms), whatever animates: the same without the glass fade,
without the corner and crop animations, with the panel kept just short of opaque,
or with the panel left in place and transparent between openings. A zoom that
waits 60 ms opens on time once the daemon is warm (13-14 late frames per eight
openings against 25-27; 40 ms gave half that gain, 80 ms no more). On a display
with adaptive refresh it waits two frames, for the 80 Hz reason above.

The closing zoom waits the same way, unless the fingers or an opening still
running already move the scene. Closed a second after it opened, the Overview
gains nothing from it. Closed after four seconds, which is how it is used, the
compositor showed the zoom's first frame and then nothing for 40 to 70 ms:
eight such holes in eight closings, none with the lead, so the motion is seen no
later than before. Releasing the previews after the zoom instead of before it
did not remove the hole.

Measure with rest between actions (`DEFI_PROBE_REST=4` for the probe): one
second apart, the compositor still holds what the previous action showed, and
a start that is late in daily use reads as on time.

A scratchpad parking slides off the top of the screen before its spring settles:
nothing changes on screen in the rest of the motion, so the compositor renders
nothing and the probe counts those 30-60 ms as late frames nobody sees.

## Tried without a gain beyond noise

- delaying native moves (25 ms, or to the end of the spring), or spacing them by 16 ms
- parking every moving window at motion start and placing it at the landing
  (two writes per window; worse)
- an opaque overlay, always or only during bursts
- keeping border windows shown, or stopping the border settle loop after landing
- deferring landing captures by 700 ms, or focus writes past the motion
- keeping overlay layers alive at zero opacity between motions
- dropping layers off screen on one side for the whole motion
- writing parked windows 220 ms later
- removing the Overview's closing glass fade
- leaving still parked windows of other workspaces off the overlay
- fading the cheatsheet without group opacity
- for the frames a motion loses as it starts after a few seconds of rest: no
  wallpaper under the overlay, pictures handed over as IOSurfaces (worse), no
  recapture between motions, a small layer animating all the time or a
  full-screen one from just before the command, pictures kept composited in a
  two-point corner (worse), and an overlay that stays just short of opaque
- capturing a new window's mid-motion picture at nominal resolution: it removes
  the late frames around 180 ms of an opening, but the opening's cadence stays
  within noise
