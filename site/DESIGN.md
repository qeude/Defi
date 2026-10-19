# Defi landing-page design

Homebrew is the primary action for Mac users and developers arriving from GitHub
and communities. The hero keeps the exact two-line headline “Your desktop,” and
“without the edges.” A category description, compact copy control, and GitHub
link precede the real columns recording in a centered vertical composition.

The background is near black (`#050505`), with white text and restrained gray,
pearl light, with one blue accent taken from the app icon (`#2b6df2`, `#7fa6ff` for text on dark). Cabinet Grotesk supplies headings and the closing
Defi signature; DM Sans supplies body text and IBM Plex Mono the command.
The softened artwork extends behind the hero and features. Gradual masks at the
top, reflection boundary, and bottom prevent hard visual cutoffs.

Velours responds to pointer movement by bending the light locally. A gradual
attack, damped center motion, and soft release retain inertia without increasing
visual intensity. One animation-frame loop stops at rest, while hidden and
offscreen states settle immediately. Mobile, coarse pointers, reduced motion,
and unavailable WebGL retain a static image. Artwork provenance is recorded in
[ART-DIRECTION.md](ART-DIRECTION.md).

The minimal pill navigation contains Defi, Features, Shortcuts, FAQ, and GitHub
as a plain text link (no second capsule inside the pill). The page keeps to the reference Mac app pages
(Screen Studio, macshot, Swiftcord, Linear, Raycast, Droppy, Framer, Attio) in
copy as well as layout: few words.

Accent is blue from the app icon (`#2b6df2`). It no longer fills any button:
the command capsule is neutral glass with only `brew` in the soft blue, and the
closing button is pearl white. Blue is kept for focus rings and key presses in
the motion piece.

1. Hero: headline, the Homebrew command as the one primary action (the only
   place the command is written out), one meta line, and the hero recording: a
   crowded desktop, Launch Defi, windows settling into place, then moving between
   columns with a keypress.
2. Features: Workspace Overview, Column widths, and Virtual workspaces. Each is a
   benefit title (56px) over a recording the width of the hero card. The hero
   already shows the before and after, so that moment is not repeated. All
   recordings are silent, muted loops that pause when scrolled out of view.
3. First launch (two steps) beside the four default shortcuts.
4. FAQ, in plain rows with a plus sign. Per-monitor behavior lives here.
5. Closing card: a button that copies the install command and Star on GitHub.
   The command is not written out again.
6. Footer: wordmark, one line (alpha, MIT, Niri), GitHub.

All sections share one 1040px content width and one left edge.

The hero recording starts as a framed card parked on its first frame and opens to
the full viewport width as the page scrolls; it starts playing as it opens and
rests again when scrolled back to the top. The silent recordings show no
player controls. Under reduced motion nothing autoplays and native controls appear.
