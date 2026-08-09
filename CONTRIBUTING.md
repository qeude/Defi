# Contributing

Defi is `0.1.0-alpha`: experimental macOS software. APIs, behavior, and
configuration may change before the first stable release.

## Prerequisites

- macOS 14 or newer
- Swift 6.2 or newer
- Accessibility permission for desktop tests and local runtime checks

## Checks

Run deterministic checks before opening a pull request:

```sh
swift build
swift test --skip DesktopE2ETests
```

Run desktop checks only on a development Mac with a disposable desktop state:

```sh
./script/test_desktop.sh
```

Desktop tests move real windows. They restore changed windows and restart the
installed service, but do not run them while important unsaved work is exposed.

## Code boundaries

- Keep `DefiModel`, `DefiCore`, `DefiConfig`, `DefiRuntime`, and `DefiIPC`
  independent from AppKit, ApplicationServices, and CoreGraphics.
- Route state mutation through `DefiRuntime`.
- Keep Accessibility writes asynchronous, bounded, and diffed.
- Add deterministic tests for layout, parsing, commands, and state changes.
- Add or run desktop validation for focus, parking, animation, hotkeys, mouse,
  or multi-monitor behavior.

## Pull requests

Describe the user-visible change, tests run, and known limitations. Use a
focused branch and conventional prefix such as `feat/`, `fix/`, `docs/`, or
`refactor/`. Keep alpha-scope changes small and reversible.
