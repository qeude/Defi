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
controls.

## Tried without a gain beyond noise

- delaying native moves (25 ms, or to the end of the spring), or spacing them by 16 ms
- parking every moving window at motion start and placing it at the landing
  (two writes per window; worse)
- an opaque overlay, always or only during bursts
- keeping border windows shown, or stopping the border settle loop after landing
- deferring landing captures by 700 ms, or focus writes past the motion
- keeping overlay layers alive at zero opacity between motions
- starting springs 8 or 16 ms after the commit
- dropping layers off screen on one side for the whole motion
- writing parked windows 220 ms later
- removing the Overview's closing glass fade
