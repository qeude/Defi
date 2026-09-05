# Contributing

Defi is `0.2.0-alpha`: experimental macOS software. APIs, behavior, and
configuration may change before the first stable release.

## Prerequisites

- macOS 26 or newer
- Swift 6.2 or newer
- Xcode 26 or newer for app icon compilation and signing tools
- Accessibility permission for desktop tests and local runtime checks

## Build and run

Clone the repository, then build, sign, and launch the app:

```sh
git clone https://github.com/qeude/Defi.git
cd Defi
./script/build_and_run.sh
```

The script installs `~/Applications/Defi.app`. It requires a full Xcode
installation and an Apple Development signing identity. If multiple identities exist,
copy `.env.example` to the ignored `.env.local` and select
`DEFI_DEVELOPMENT_TEAM`, or set `DEFI_CODESIGN_IDENTITY` to an exact identity.
You can also create the self-signed identity described under
[Release packaging](#release-packaging) and build with:

```sh
DEFI_CODESIGN_IDENTITY='Defi Release' ./script/build_and_run.sh
```

Preserve the installed app's signing identity between builds so macOS keeps its
privacy permissions. Grant Accessibility access on first launch, then reopen
the app.

The script never creates or replaces `~/.config/defi/config.toml`. Existing
local settings stay in use across builds; without a config, Defi uses its
built-in Option shortcuts and unnamed workspaces. `config.example.toml` is
the maintainer's optional setup, not an installation default.

## Checks

Run deterministic checks before opening a pull request:

```sh
swift build
swift test --skip DesktopE2ETests
```

Verify the installed build with `./script/build_and_run.sh --verify`, using
the same signing identity as your existing installation.

Run desktop checks only on a development Mac with a disposable desktop state:

```sh
./script/test_desktop.sh
```

Desktop tests move real windows. They restore changed windows and restart the
installed service, but do not run them while important unsaved work is exposed.

## Development scripts

| Script | Purpose |
| --- | --- |
| `build_and_run.sh` | Build, sign, install, and launch Defi. |
| `resolve_signing_identity.sh` | Select the signing identity for the build script. |
| `setup_release_certificate.sh` | Create the stable local release certificate. |
| `package_release.sh` | Package the signed app as a ZIP with a checksum. |
| `test_desktop.sh` | Stop Defi, run desktop tests, and restore the app. |

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

## Release packaging

Release archives are signed with a stable self-signed certificate and are not
notarized. The planned Homebrew Cask removes quarantine automatically. For a
manual installation of an official release, move `Defi.app` to
`/Applications`, then run:

```sh
xattr -dr com.apple.quarantine /Applications/Defi.app
open /Applications/Defi.app
```

Only use archives from the official Defi repository. Homebrew distribution
should document `brew install --cask qeude/tap/defi` and
`brew uninstall --cask --zap defi` once the Cask is published.

Create the stable self-signed release identity once:

```sh
./script/setup_release_certificate.sh
```

Back up `Defi Release` from Keychain Access to encrypted offline storage. Never
commit or upload the exported private key.

After the required checks pass, create the non-notarized arm64 ZIP and checksum:

```sh
./script/package_release.sh
```

The script validates the bundle signature and architecture, rejects private
key material, provisioning profiles, personal source paths, and email addresses,
then writes `Defi-v<version>.zip` and its SHA-256 file under `dist/`. Upload only
those two files to the matching prerelease tag.

Finally, update `qeude/homebrew-tap` with the release URL and SHA-256. The Cask
must install `Defi.app`, remove `com.apple.quarantine` in `postflight`, and zap:

- `~/.config/defi`
- `~/Library/Application Support/Defi`
- `~/Library/Caches/com.quentin.defi`
- `~/Library/Logs/Defi`
- `~/Library/Logs/Defi.log`
- `~/Library/Preferences/com.quentin.defi.plist`
- `~/Library/Saved Application State/com.quentin.defi.savedState`
- `~/Library/LaunchAgents/com.quentin.defi.plist` for legacy installations

The Cask should also expose `Defi.app/Contents/MacOS/defi` through a `binary`
stanza.

See [PERFORMANCE.md](PERFORMANCE.md) for performance investigation guidance.
