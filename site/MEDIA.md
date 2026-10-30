# Defi landing media

The hero no longer uses a recording: it is the interactive preview in
`desk.js`. One recording remains, in the feature bento; the desk already shows
workspaces, so the workspaces clip was dropped.

| File | Length | Size | Used by |
| --- | --- | --- | --- |
| `feature-overview.mp4` | 6 s | 1280 × 720, 120 fps | “Every window at a glance” card |

It is cut from a 2560 × 1440 ScreenCaptureKit recording of the installed app
on 30 October 2026 (menu bar and Dock included): a browser workspace, a
workspace of terminals, and the Overview opening on them. Defi was driven
through the `defi` CLI (`focus-workspace`, `focus-column`, `cycle-width`,
`toggle-overview`) at human pace, with `RibbonProxyCapturable` set for the
recording only, so the ribbon overlay appears as it does on screen. The cursor
is hidden. A private calendar item in the menu bar is blurred with `delogo`.
The poster is a mid-clip frame (`feature-overview.jpg`).

Encoding: `fps=120`, scale to 1280 × 720, `-crf 27`, `-preset slow`,
`-movflags +faststart`, no audio.

The film for the README and social media (not on the site) is one continuous
shot in the landing's art direction: 51 s, 1920 × 1080, H.264 two-pass with
a deep electro track synthesized for it on the film's beat grid, at 120 fps
(README) and 60 fps (X).
Unlike the Overview clip, it is not footage: it is rendered frame by frame from
real window pictures, with Defi's column widths, stacks, Overview rows and
spring (stiffness 800), every key press on the music's beat grid. Two terminal
pictures draw real command output (`git log`, `ls`), and the second display
reuses windows from the first. The scene, renderer and pictures live outside
the repository in `~/.t3/defi-motion8`.

Frame rate: ScreenCaptureKit delivers 120 fps while columns scroll and the
Overview moves. Vertical workspace switches arrive at about 60 fps in the
capture; those stretches repeat frames in the 120 fps files.

`og.jpg` (1200 × 630) is the link preview image declared in `index.html`, made
from real window captures in the desk's frame. Its URLs are absolute, so they
must change if the site moves to another domain.
