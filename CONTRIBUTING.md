# Contributing

Defi is experimental macOS software. APIs, behavior, and
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

Run the complete automated verification:

```sh
python3 script/verify.py full --filter DesktopE2ETests/testSnapshotUsesUniqueWindowIDsPerProcess
```

Omit `--filter` for the full native suite. Preparation happens locally; installation
and native tests wait for the shared desktop reservation. A failed preparation
never installs. The loop requires one running installed daemon for its session
checkpoint. Visual inspection remains a separate check when required by the change.

Inspect live progress from another terminal:

```sh
python3 script/verify.py status
python3 script/verify.py status dist/verification/<run-directory>
```

Reports update atomically at each phase and step completion. Status includes the
desktop owner's PID, project directory and report path, and elapsed time in the current
phase. A killed process can leave a running report; `process_alive` distinguishes
that case. The OS lock, rather than the retained owner metadata, determines availability.

Run the local loop while continuing to use your desktop:

```sh
python3 script/verify.py local
```

It builds and runs Swift tests excluding `DesktopE2ETests`, plus the workflow
checks. It forces `DEFI_E2E=0` even if your shell enabled it. Tests using AppKit
notification centers or fake AX elements stay local; actual window mutation,
event posting, and global hotkey capture belong in `DesktopE2ETests`.

Prepare a signed app without stopping the installed daemon:

```sh
python3 script/verify.py local --stage
```

The command prints a run directory under `dist/verification/` with `result.json`,
step logs, source identity, and the staged bundle's SHA-256. Use that directory
for the exclusive desktop phase:

```sh
python3 script/verify.py desktop dist/verification/<run-directory> --wait
# Or target one native scenario:
python3 script/verify.py desktop dist/verification/<run-directory> --wait --filter DesktopE2ETests/testSnapshotUsesUniqueWindowIDsPerProcess
```

This installs the exact prepared bundle without rebuilding it. It rejects source
or artifact changes, compiles test code before reserving the desktop, and records
normalized XCTest XML plus status and trace logs. XCTest case events are read
from the serial runner: SwiftPM's parallel XML writer can hide skipped cases. Zero executed tests or skipped tests
produce an incomplete result, not a full pass. Visual inspection remains separate
and is always reported as `not-run`; automated checks do not certify animation
quality or realistic Dock and Command-Tab interactions.

Without an explicit identity override, signing reuses the installed app's
certificate when available. Installation requires both the same certificate and
the same designated requirement, checked before stopping the daemon. If its key
is unavailable, restore that signing identity rather than selecting another one.
The checks do not reset or grant privacy permissions.

Before installation, verification stops the daemon to flush and checkpoint its
existing topology and placement stores. After tests, including failures, it
restores those files with the daemon stopped, restarts it, and checks every
monitor's workspace structure, logical focus, column widths, scroll and managed
frame convergence. The checkpoint and observed restoration are retained with the
run. Closed windows, changed monitors, or intervening human input can prevent exact
restoration; that produces a failed check instead of a pass. These checks do not
certify native focus or visual appearance.
Session identity uses the boot UUID and audit session ID, so restarts retain the
same topology while another login or boot cannot reuse stale window identities.

The installer copies and verifies a candidate before stopping the app, keeps the
previous bundle during startup, and recovers it if replacement or readiness fails.
If a daemon refuses to stop during recovery, it retains the backup and reports its
path rather than replacing a running bundle. Debug mode commits the installation
before handing control to LLDB.

A per-user file lock serializes installation and desktop tests.
Busy commands exit with code 75; the OS releases the lock when its
owning processes exit. Do not delete the lock file to bypass contention.
With `desktop --wait`, the command waits and resumes automatically when the
reservation becomes available. It rechecks source and bundle hashes before
installation; changes during the wait invalidate the run. Waiting does not
guarantee FIFO ordering. Cancel with Ctrl-C.

For manual visual validation, reserve the desktop in an interactive shell:

```sh
python3 script/desktop_lock.py --wait bash
# Run installation/desktop commands here, then inspect the app while this shell lives.
# Restore the original workspace, confirm one daemon, and exit to release the desktop.
```

The lock does not prevent human input. Desktop tests still move real application
windows and need a development desktop. Keep realistic interaction checks focused
on the changed behavior and the final build.

`./script/build_and_run.sh --verify` remains a build/install/readiness shortcut;
`./script/test_desktop.sh [DesktopE2ETests/testName]` remains available for native
tests. Both use the same desktop reservation. The test script restores a previously
running service on success, failure, or handled interruption.

## Development scripts

| Script | Purpose |
| --- | --- |
| `verify.py` | Local preparation or exclusive desktop verification with recorded results. |
| `desktop_lock.py` | Reserve the desktop across concurrent and nested commands. |
| `desktop_session.py` | Checkpoint and restore existing session stores under the desktop reservation. |
| `check_signing.sh` | Compare certificates and designated requirements without mutation. |
| `build_and_run.sh` | Build, sign, install, and launch Defi; `--install-staged` reuses a prepared bundle. |
| `resolve_signing_identity.sh` | Select the signing identity for the build script. |
| `setup_release_certificate.sh` | Create the stable local release certificate. |
| `package_release.sh` | Package the signed app as a ZIP with a checksum. |
| `update_homebrew_release.sh` | Open a Cask update PR using a published release checksum. |
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
notarized. The Homebrew Cask removes quarantine automatically. For a
manual installation of an official release, move `Defi.app` to
`/Applications`, then run:

```sh
xattr -dr com.apple.quarantine /Applications/Defi.app
open /Applications/Defi.app
```

Only use archives from the official Defi repository. Install through Homebrew
with `brew install --cask qeude/tap/defi`; remove the app and its user data with
`brew uninstall --cask --zap defi`.

Create the stable self-signed release identity once:

```sh
./script/setup_release_certificate.sh
```

Back up `Defi Release` from Keychain Access to encrypted offline storage. Never
commit the exported private key or attach it to a release. The encrypted export
may be stored only as a protected GitHub Actions secret for automated signing.

### Automated releases

After merging the version and build-number changes in `Support/Defi-Info.plist`,
push a matching tag from `main`, for example `v0.2.2`. The Release workflow checks
the version and ancestry, runs the build and tests, then waits for approval of
the `release` environment. Inspect the tagged commit before approving it.

The signing job uses a temporary keychain, verifies the existing certificate
fingerprint, packages the app, and removes the signing files. It publishes only
the ZIP and checksum. Stable tags then open a PR in `qeude/homebrew-tap`, which
must be reviewed and merged separately. Prerelease tags do not update the Cask.

Configure the `release` environment with a required maintainer reviewer and
deployment rules allowing only `v*` tags and `main`. Store these environment secrets:

- `DEFI_RELEASE_P12_BASE64`: Base64-encoded encrypted export of the existing
  `Defi Release` certificate **and private key**.
- `DEFI_RELEASE_P12_PASSWORD`: the export password.
- `HOMEBREW_TAP_TOKEN`: a fine-grained token restricted to `qeude/homebrew-tap`,
  with Contents and Pull requests read/write access. Renew it before expiration.

The maintainer can approve their own deployment, so a solo-maintained repository
does not require a second account. Homebrew is a separate job and may require
another environment approval. If it fails, rerun only that failed job; it reads
the published checksum and does not rebuild or replace the release.

Use **Actions → Release → Run workflow** on `main` to verify signing and
packaging without publishing a release or creating a Homebrew PR. A published
release cannot be overwritten by a workflow retry. A failed draft upload can
be retried before publication.

See GitHub's [certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
and [environment protection](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
documentation for secret storage and approval controls.

### Local packaging

After the required checks pass, create the non-notarized arm64 ZIP and checksum:

```sh
./script/package_release.sh
```

The script validates the bundle signature and architecture, rejects private
key material, provisioning profiles, personal source paths, and email addresses,
then writes `Defi-v<version>.zip` and its SHA-256 file under `dist/`. Upload only
those two files to the matching release tag.

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
