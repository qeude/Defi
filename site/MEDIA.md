# Real Defi media

All desktop footage comes from the existing public Defi README recording:

https://github.com/user-attachments/assets/3d21bd27-d5ef-477b-826f-1f9abca32a95

The recording is 1920 × 1246, H.264, 19.083 seconds. It shows real horizontal
navigation and workspace Overview. This is existing alpha footage, not a claim
that the current build was freshly recorded. It contains the original development
desktop, including a terminal size warning during one passage. A dedicated clean
capture can replace these files after the visual direction is selected.

Screenshots are full, uncropped frames from the same recording:

| File | Timestamp | View |
| --- | --- | --- |
| `defi-desktop.jpg` | 0 seconds | Browser and adjacent tiled terminal |
| `defi-columns.jpg` | 8 seconds | Scrolling terminal columns |
| `defi-overview.jpg` | 12 seconds | Workspace Overview |

Reproduce from a local copy of the source video:

```sh
ffmpeg -ss 0 -i source.mp4 -frames:v 1 -q:v 2 public/media/defi-desktop.jpg
ffmpeg -ss 8 -i source.mp4 -frames:v 1 -q:v 2 public/media/defi-columns.jpg
ffmpeg -ss 12 -i source.mp4 -frames:v 1 -q:v 2 public/media/defi-overview.jpg
```

The app icon is copied from `docs/assets/defi-icon-dark.png`. The page loads
media locally and does not depend on GitHub's attachment service at runtime.

The four feature illustrations are temporary until genuine feature clips
replace them. The capture plan below remains the replacement plan.

## Next capture: one feature per clip

Record the installed app on a prepared demo desktop with public content, three
or four native app windows, and two populated workspaces. Keep the same wallpaper,
display size, app contents, and framing across the set. Hide notifications and
personal titles. Use ordinary human timing and capture real behavior, including
its actual animation speed. Do not recreate app UI or interpolate window motion.

| Asset | Duration | Sequence | Page placement |
| --- | --- | --- | --- |
| `feature-columns.mp4` + poster | 8–10 s | Pause; focus right twice until an offscreen column enters; return left once; pause. | Hero / continuous columns |
| `feature-workspaces.mp4` + poster | 6–8 s | Switch from one populated workspace to another, then return. | Future workspace recording |
| `feature-overview.mp4` + poster | 8–10 s | Open Overview, pause to show workspace rows, select a window. Requires enabled previews for thumbnail footage. | Separate Overview chapter |
| `feature-widths.mp4` + poster | 6–8 s | Cycle the selected column width twice, showing sibling reflow; restore its width. | Future width recording |

Use full-resolution screenshots at the settled moment of each sequence. Export
silent H.264 MP4 with progressive playback and a JPEG poster, keeping the real
desktop proportions. Native controls remain available. The hero can reuse the
columns clip; separate clips should demonstrate only their named feature.

Capture assessment on 2026-09-30: the current desktop contained private project
content, Overview previews were disabled, and an Accessibility query timed out.
No fresh feature media was saved and no desktop state was changed. Prepare a
clean demo desktop before recording; these asset names are planned, not existing
files. Keep the public README footage in place until replacements are captured.

## Existing media inventory

The hero and separate Overview chapter use real recordings. Both keep their
original colors, full frame, and 1920 × 1246 aspect ratio. Short excerpts are re-encoded to H.264
without audio or interpolated frames, with progressive playback enabled.

| Asset | Source range | Use |
| --- | --- | --- |
| `defi-columns-clip.mp4` | 1.4–5.6 s | Hero only; excludes the later terminal warning |
| `defi-overview-clip.mp4` | 8.5–13.5 s | Separate Overview chapter |
| `defi-workspaces.jpg` | 15 s | Retained source still; not shown in the theatre |
| `defi-desktop.jpg` | 0 s | Retained source still; not a width-change recording |

These are excerpts of the published alpha recording, not fresh feature captures.
Dedicated workspace-switching and width-change clips remain planned above.
The four theatre scenes are abstract interactive illustrations, not recordings
or product screenshots. Columns, workspaces, Overview, and widths each have a
bounded demonstration on selection or Replay. They do not autoplay or loop.
There is no multi-monitor capture in the current inventory.

```sh
ffmpeg -ss 1.4 -i source.mp4 -t 4.2 -an -c:v libx264 -preset fast -crf 21 -movflags +faststart public/media/defi-columns-clip.mp4
ffmpeg -ss 8.5 -i source.mp4 -t 5 -an -c:v libx264 -preset fast -crf 21 -movflags +faststart public/media/defi-overview-clip.mp4
ffmpeg -ss 15 -i source.mp4 -frames:v 1 -q:v 2 public/media/defi-workspaces.jpg
```
