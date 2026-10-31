# Defi landing-page design

Reference: [openbot.run](https://openbot.run/), for its hierarchy, its
interactive product preview, its HTML illustrations, and its restrained motion.

The background is a soft near black (`#1b1b1d`) with cards one step lighter
(`#222225`) and hairline borders. Blue from the app icon (`#2b6df2`) carries
the brand: the hero light, the wallpaper and the illustrations. In the desk,
the focused window's border is white. Cabinet Grotesk sets headings, DM Sans
the body, IBM Plex Mono the command and code. White pills are primary actions;
outlined pills are secondary.

Rhythm and type:

- Sections share one width, `--page` (90% of the viewport, 1180 to 1480 px),
  and one opening space, `--section` (96 to 144 px), with none at their end.
  The closing takes 40 px more to mark the end.
- Headings: 96 px for the title, 64 px for sections, 24 px for cards. Below
  them, three text sizes: 19 px ledes, 16 px body, 13 to 14 px small print.
- Illustrations size from their card (container units), so they fill it at
  every width.
- The nav floats with no band behind it; its pills are dense glass, so content
  passing under them never reads through.

1. Navigation: wordmark, a centered pill of section links, GitHub and Install.
2. Hero: an alpha badge, the title “Your desktop, without the edges.”, whose
   last word comes apart: its letters blur towards the end and shed a little dust, and
   the pointer brings them back into focus and pushes the dust aside. Then the Homebrew command as a white copy pill whose chevron opens the other
   install methods (curl, DMG), GitHub, then the interactive desk: a dark-mode Mac with Defi running (see
   README.md), a blue gradient wallpaper that matches the hero, a keypad of the main
   shortcuts that light up as keys are pressed, and a ⌃⌥ entry that shows the cheatsheet while held. The desk is capped so that, opened,
   it runs edge to edge and fits one screen with the keypad under it. A title across the top
   of the desk, “Go on, press ⌃⌥→”, plays the demo's shortcuts on its keys (the modifiers go down and stay, then the key lands), names the action and fades as soon as the
   visitor takes over.
3. What Defi does: an uneven twelve-column bento of six cards with one-line
   descriptions. The Overview recording fills a tall card (7 columns, 2 rows)
   beside two stacked cards: Command-Tab and speed, its copy beside “120 Hz”
   (system face, snapping up from 0 out of a blur) over the footer's light
   columns, which rise behind it and then breathe slowly. Below, three cards
   of falling width (5, 4 and 3 columns): app rules (a real capture of Defi's Settings, fading into the card),
   monitors (small Defi desktops: wallpaper, windows with their app icon, white
   focus border), and the command line (real `defi` commands). The desk above
   already shows columns reflowing and windows floating.
   Every claim matches the code or CONFIGURATION.md.
4. Shortcuts: “Hold ⌃ ⌥” (two keycaps) beside Defi's real cheatsheet for the
   built-in keys, laid out like CheatsheetView (black fading into glass, chord,
   action, Shift chord, action), over two windows on the desk wallpaper. The
   desk's cheatsheet uses the same markup.
5. FAQ: two columns, plus signs that turn into minus signs.
6. Closing: icon, title, install command, Star on GitHub, then the footer over
   Defi's columns as light: equal heights, preset widths, 8 px gaps, one
   brighter focused column. They reach the page bottom, rise as it scrolls in
   and scroll sideways in a seamless loop.

Under 900px the bento and the two-column sections become one column and the
section pill is hidden. Reduced motion stops the demo, the dissolving title, the reveal transitions
and the decorative loops. The fake apps inside the desk are hidden from
assistive technology; the keypad under it is the accessible control.
