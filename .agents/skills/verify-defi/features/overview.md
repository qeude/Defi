# Overview with window previews

## Sub-features

- Open and close with `toggle-overview` or the configured hotkey.
- Window previews captured through ScreenCaptureKit, with title and icon.
- Desktop background per monitor.
- Keyboard navigation and window moves inside the overview.
- Zoom transition between native windows and Overview cards, with or without previews.

## How to get to it (user POV)

Press the overview hotkey, or run `defi toggle-overview`. Previews need Screen Recording permission (`overview.window_previews`, default `true`); without it the Overview shows cards and the zoom still runs.

## Driving it with the defi CLI

```sh
defi toggle-overview; sleep 3
defi status | tr ' ' '\n' | grep -E '^overview(=|Permission|Captures|Previews|ReceivedPreviews|PreviewFailures|FirstPreviewMs)'
defi toggle-overview
```

Pass: `overview=open`, `overviewPermission=granted`, `overviewReceivedPreviews` greater than 0, `overviewFirstPreviewMs` a number. For visuals take a Computer Use screenshot while open and confirm cards show window content and the desktop background, not flat grey.

## Gotchas

- Status is published on change. Read it a few seconds after opening; `overviewCaptures` is in-flight work and returns to 0.
- `overviewReceivedPreviews=0` with `overviewPreviewFailures=0` and no ScreenCaptureKit activity in the log means captures never started, usually a wedged daemon. `defi service restart` recovers it. Check `/usr/bin/log` for `overview-capture` errors.
- The overview can close on its own when focus changes; poll `overview=` rather than assuming it stayed open.
- Another covering test: `DesktopE2ETests/testOverviewOpensOnEveryDisplayAndZoomsWithOrWithoutPreviews`.
