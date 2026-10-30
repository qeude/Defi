# Defi landing page

The page follows the structure of [openbot.run](https://openbot.run/): a short
hero over an interactive preview of the product, a bento grid of features, Defi's cheatsheet, the FAQ, and a
closing install action.

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

The build creates `site/dist/` with relative asset URLs, suitable for a static
host or repository subpath. Pushes to `main` that touch `site/` are published to
GitHub Pages by `.github/workflows/site.yml`. The first dev or build run
downloads Cabinet Grotesk from Fontshare; later runs reuse the local file.

- `main.js` composes the page, the copy buttons, the desk's opening on scroll,
  the columns of light at the page bottom,
  and the feature clips' playback.
- `desk.js` is the interactive preview: a 1440 × 900 point Mac in dark mode,
  drawn in HTML at real size and scaled to fit. It uses Defi's built-in
  defaults: 8 pt gaps, a 4 pt border outside the focused window (drawn in white rather than the app default `#C099FF`),
  widths cycling through 0.33, 0.5, 0.66 and 0.8, scrolling only as far as
  needed (`center_focused_column = "never"`), one empty trailing workspace, an
  Overview drawn like OverviewView (zoom 0.5, rows 28 pt apart on their
  wallpaper, titles inside the cards, "← N" pills, 0.22 s zoom and 0.16 s moves),
  and Defi's spring (mass 1, stiffness 800). The menu bar carries Defi's workspace item and menu, the Dock activates
  an app's window on its workspace, and holding Control-Option shows the cheatsheet.
  Every built-in Control-Option shortcut drives it while it is on screen, with
  no click needed, following DefiCore: columns, stacks (`J`/`K`, join with `;`
  and `'`, unjoin with `R`), floating windows (`\`, `,`, `.`), widths, workspaces
  and 1–9; Shift moves. The monitor shortcuts do nothing, as on a single display.
  In the Overview, plain arrows put the selected column at the row's left edge,
  the pills page a row by one column, cards drag into a stack or a new column,
  and Return or Escape close it. A short demo plays
  until the visitor takes over, never under reduced motion.
- The preview opens on an ordinary crowded desktop. When the visitor scrolls,
  or after a moment, Defi opens from Spotlight and the windows leave the pile
  for their columns and workspaces. As the page scrolls, the framed desk opens to
  the full viewport width. A key press or click before that skips the intro.
- Windows beyond the screen stay hidden, as Defi parks them: the desk shows
  only what the display would.
- The desk's wallpaper is the CSS gradient `--wallpaper` in `style.css`, in the
  hero's blues. The cheatsheet section reuses it.
- `style.css` holds every style. Sizes inside the preview use container units,
  so the same markup serves the hero desk and the cheatsheet section.

Feature clips are muted, looping and `playsinline`, play while on screen in a
visible tab, and show native controls instead under reduced motion.

See [DESIGN.md](DESIGN.md), [MEDIA.md](MEDIA.md), [ART-DIRECTION.md](ART-DIRECTION.md)
and [THIRD-PARTY.md](THIRD-PARTY.md).
