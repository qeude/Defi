# Defi landing media

## Current recordings

The hero and the three feature clips come from one 3840 × 2160 recording of the installed app
(menu bar and Dock included, nothing cropped): a browser workspace, a T3 chat
workspace, one workspace of terminals (cmatrix, btop, fastfetch), and the
Overview. Dead time between gestures is cut. The clips are silent H.264 at 60 fps
so the real window motion is preserved; nothing is interpolated or slowed, except in the hero (described below).
Workspace switches in the recording are instant cuts, so the workspaces clip is
three real workspaces cut together on the real switch frames.

| File | Length | Size | Used by |
| --- | --- | --- | --- |
| `feature-hero.mp4` | 7.2 s | 1920 × 1080 | Hero (crowded desktop, Launch Defi, tidy windows, moving between columns) |
| `feature-hero-hd.mp4` | 7.2 s | 2880 × 1620 | Same hero for viewports of 2200 device pixels or more (Retina) |
| `feature-widths.mp4` | 8.6 s | 1920 × 1080 | Column widths feature |
| `feature-workspaces.mp4` | 4.1 s | 1920 × 1080 | Virtual workspaces feature (GitHub, T3 chat, terminals) |
| `feature-overview.mp4` | 8.7 s | 1920 × 1080 | Overview feature |

The hero is a short cut of the motion film's opening (`index.html?hero=1` in the motion
project; the film itself is for social media and is not on the site), rendered at 1.5× (2880 × 1620): 0.6 s of the real crowded desktop,
the Raycast panel (a still) and the windows leaving to their workspaces, both
composed from real window textures of the same recording. Then it hands over, with
a short cross-fade, to the real footage of moving between columns with Option and
the arrow keys (3.35 s, two key presses shown). The capture steps through
each column move in about ten uneven frames, so both moves are rebuilt as one
0.4 s eased slide with motion blur from stills of the same footage (`smooth.py`
in the motion project): same windows, same focus ring, nothing invented. No captions. It loops with a 0.4 s
cross-fade. The card rests on
the first frame; `hero-grow.js` starts the clip as soon as the page starts opening
it, so Defi is tidying the windows around the time the frame reaches full width. `main.js` swaps in the HD file when `devicePixelRatio × innerWidth`
is 2200 or more, unless the browser asks to save data.

Each clip has a poster (`feature-*.jpg`) taken mid-clip. The four
silent clips weigh about 3.6 MB; only the hero clip is preloaded, the others
load when played.

The film (house music, 132.5 BPM, 60 fps) is the source of the hero. Its scene file
and music generator live outside the repository (`~/.t3/defi-motion7`: `index.html`,
`genres.py`); the 37 s web encode is kept there as `web-film/`.

Retouch: the private calendar item in the menu bar is painted over with a
horizontal gradient sampled on either side of it. Nothing else is altered.

Encoding: `trim`/`concat`, scale to 1920 × 1080, `-crf 28`, `-preset slow`,
`-movflags +faststart`, no audio. The hero is encoded from the 2880 × 1620 render
at `-crf 24` (HD, kept at full size) and `-crf 26` (scaled to 1920 × 1080).

Known weak spots: the cmatrix terminal restarts (and looks empty for a moment)
after every width change, and the Overview clip ends on fastfetch, which shows
the hostname. The T3 sidebar (thread titles) and fastfetch (hostname, IP) are
visible in the hero and the workspaces clip. The owner reviewed these details and
accepted them for publication. There is no multi-monitor capture and no cheatsheet clip yet.
