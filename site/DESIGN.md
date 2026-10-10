# Defi landing-page design

Homebrew is the primary action for Mac users and developers arriving from GitHub
and communities. The hero keeps the exact two-line headline “Your desktop,” and
“without the edges.” A category description, compact copy control, and GitHub
link precede the real columns recording in a centered vertical composition.

The background is near black (`#050505`), with white text and restrained gray,
pearl, and lavender light. Cabinet Grotesk supplies headings and the closing
Defi signature; DM Sans supplies body text and IBM Plex Mono the command.
The softened artwork extends behind the hero and features. Gradual masks at the
top, reflection boundary, and bottom prevent hard visual cutoffs.

Velours responds to pointer movement by bending the light locally. A gradual
attack, damped center motion, and soft release retain inertia without increasing
visual intensity. One animation-frame loop stops at rest, while hidden and
offscreen states settle immediately. Mobile, coarse pointers, reduced motion,
and unavailable WebGL retain a static image. Artwork provenance is recorded in
[ART-DIRECTION.md](ART-DIRECTION.md).

The minimal pill navigation contains Defi, Features, and GitHub with an icon.
Below the recording, the feature guide groups the section heading, explanation,
and four persistent choices beside a shared illustration panel. Feature names
are the primary selector text; actions are their descriptions. The guide may
briefly pin on sufficiently wide and tall screens, with no artificial scroll
space. Narrower layouts use document flow and two-column feature choices.

The four illustrations are temporary, visibly labelled “Interactive
illustration,” and include accessible descriptions. They do not simulate app
footage. See [MEDIA.md](MEDIA.md) for the replacement recording scenarios.
Feature controls use native buttons with `aria-pressed` and `aria-controls`;
selection preserves keyboard focus and updates the panel caption and shortcut.
Replay remains mounted and respects reduced motion.

The remaining chapters cover per-monitor behavior, a real Overview recording,
compatibility and permission questions, and first launch. The final footer holds
the large Defi signature, Niri attribution, native macOS fact, alpha status, and
MIT/open-source link. All product recordings keep their native controls and
never autoplay.
