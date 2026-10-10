# Defi landing page

The vertical hero opens with the headline, a compact Homebrew command, and real
columns footage. Its muted light surface uses Velours: local deformation builds
gradually under the cursor, retains inertia, and returns softly to rest. The
background continues behind the feature section. GitHub links include its icon.

Four feature buttons share an illustration theatre. These illustrations remain
temporary until genuine feature recordings replace them. A separate Overview
chapter shows existing alpha footage. The FAQ and installation section cover
compatibility, Homebrew, opening the app, and granting Accessibility access.
Project and license facts sit in the footer. Copy is English, aimed at Mac users
and developers arriving from GitHub and communities.

```sh
cd site
npm ci
npm run dev -- --port 5173
```

Open `http://localhost:5173/`.

```sh
npm run build
npm run preview
```

The build creates `site/dist/`, with relative asset URLs suitable for a static
host or repository subpath. Nothing is published automatically. The first dev
or build run downloads Cabinet Grotesk directly from Fontshare; subsequent runs
reuse those local files. The font binaries are ignored rather than redistributed
through this repository. Initial preparation requires network access.

`main.js` owns the feature registry, page composition, copy controls, and video
lifecycle. `style.css` supplies the base layout; `direction.css` supplies the
approved composition and responsive styling. `hero-field.js` owns the shared
animation frame and visibility handling. `light-surface.js` bends the artwork
locally using WebGL; it stops drawing at rest and restores the image on context
loss. Narrow, coarse-pointer, and reduced-motion startup use the static artwork.
There are no particles or global mouse parallax. Velours is the default; the
earlier studies remain available through `?light=original`, `?light=lentille`,
and `?light=sillage`.

`optical-motion.js` supplies scroll-driven depth and briefly pins the feature
guide with GSAP. It requires a viewport at least 900px wide and 800px tall with
no reduced-motion preference. Other layouts use normal document flow.

Feature buttons support click, Enter, and Space, remain in the Tab order, and
keep focus on selection. Replay restarts only the selected illustration. Motion
ends after 750ms. Reduced-motion preference changes cancel the illustration.
The printed Option shortcuts describe Defi; the page does not handle them.

Videos have native controls, `playsinline`, and `preload="none"`. They do not
autoplay or loop. Playing one pauses the other; leaving the viewport or hiding
the document pauses playback without automatic resume. Failed recordings show
a poster and direct clip and README links.

See [DESIGN.md](DESIGN.md), [MEDIA.md](MEDIA.md), [ART-DIRECTION.md](ART-DIRECTION.md),
and [THIRD-PARTY.md](THIRD-PARTY.md) for composition, capture plans, and provenance.

Verification: `npm run build` and `python3 ../script/verify.py local` pass.
The production build was checked in the browser from a repository subpath:
images, fonts, WebGL surface, GSAP, native video controls, navigation, and footer
load without horizontal overflow. Earlier motion checks verified gradual onset,
continued release motion, exact baseline restoration, idle termination, static
mobile/reduced-motion startup, and context-loss fallback.
