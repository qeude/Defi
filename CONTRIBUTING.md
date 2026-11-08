# Contributing

Bug reports and focused pull requests are welcome. Defi is in alpha: APIs,
behavior, and configuration may change before the first stable release.

```sh
git clone https://github.com/qeude/Defi.git
cd Defi
make run       # build, sign, install, and launch
make verify    # build, tests, and workflow checks; never touches your desktop
```

**Contents**: [Prerequisites](#prerequisites) · [Build and run](#build-and-run) ·
[Checks](#checks) · [Code boundaries](#code-boundaries) ·
[Pull requests](#pull-requests) · [Configuration migrations](#configuration-migrations) ·
[Release packaging](#release-packaging) · [Development scripts](#development-scripts)

## Prerequisites

- macOS 26 or newer
- Swift 6.2 or newer
- Xcode 26 or newer, for the app icon and signing tools
- Accessibility permission, for desktop tests and local runtime checks

## Build and run

`make run` (`./script/build_and_run.sh`) installs `~/Applications/Defi.app` and
launches it. It needs a full Xcode installation and a signing identity:

- **One Apple Development identity**: nothing to do.
- **Several identities**: copy `.env.example` to the ignored `.env.local` and set
  `DEFI_DEVELOPMENT_TEAM`, or set `DEFI_CODESIGN_IDENTITY` to an exact identity.
- **Self-signed instead**: create the identity from
  [Release packaging](#release-packaging), then build with:

  ```sh
  DEFI_CODESIGN_IDENTITY='Defi Release' ./script/build_and_run.sh
  ```

Keep the same signing identity between builds, or macOS treats the app as new
and asks for its permissions again. On first launch, grant Accessibility; Defi
picks it up without a restart.

The script never creates or replaces `~/.config/defi/config.toml`. Without a
config, Defi uses its built-in Control-Option shortcuts and unnamed workspaces.
`config.example.toml` is the maintainer's setup, not a default.

## Checks

Every check runs through `make` and needs only the Swift toolchain and tools
macOS ships, such as `jq` and `lockf`.

| Command | What it does | Touches your desktop |
| --- | --- | --- |
| `make test` | Swift tests; desktop tests skip themselves. | No |
| `make verify` | Build, Swift tests without `DesktopE2ETests`, and the workflow checks in `Tests/Verification`, recorded under `dist/verification/`. | No |
| `make verify-desktop FILTER='…'` | `make verify`, then installs the signed build and runs the selected desktop tests. | Yes |
| `make verify-status` | Shows the progress of a running verification. | No |
| `make install` | Builds, installs, and checks the installed daemon starts. | Yes |

Run the desktop tests that cover the interactions you changed, and widen the
selection, up to the whole suite, wherever a side effect is plausible:

```sh
make verify-desktop FILTER='DesktopE2ETests/(testFocusFollowsLatestNativeIntent|testTiledFocusKeepsFloatingWindowAboveIt)$'
```

Omit `FILTER` for the full suite, which is required on the release commit before
tagging. `make verify-desktop` runs `script/verify.sh full`: it prepares locally,
never installs after a failed preparation, then waits for the shared desktop
reservation. It needs exactly one installed daemon running, for its session
checkpoint. Desktop tests drive only Defi-owned fixture windows. They need
Accessibility and Screen Recording, with Reduce Motion off, and fail loudly
otherwise. Automated checks do not certify animation quality or realistic Dock
and Command-Tab interactions, so inspect those by hand when your change affects
them.

`make verify` forces `DEFI_E2E=0` even if your shell enabled it. Tests using
AppKit notification centers or fake AX elements stay local; real window changes,
event posting, and global hotkey capture belong in `DesktopE2ETests`.

### Prepare now, test later

Prepare a signed app without stopping the installed daemon:

```sh
script/verify.sh local --stage
```

It prints a run directory under `dist/verification/` with `result.json`, step
logs, source identity, and the bundle's SHA-256. Run the desktop phase with it
when your desktop is free:

```sh
script/verify.sh desktop dist/verification/<run-directory> --wait
script/verify.sh desktop dist/verification/<run-directory> --wait --filter DesktopE2ETests/testFocusFollowsLatestNativeIntent
```

This installs that exact bundle without rebuilding, and rejects it if the
sources or the bundle changed. Follow progress from another terminal with
`make verify-status` or `script/verify.sh status dist/verification/<run-directory>`.

<details>
<summary>Reading a verification report</summary>

Reports update atomically after each phase and step. Status shows the desktop
owner's PID, project directory, report path, and time spent in the current
phase. A killed process can leave a running report; `process_alive` tells that
case apart. The OS lock, not the retained owner metadata, decides availability.

The desktop phase compiles test code before reserving the desktop and records
normalized XCTest XML plus status and trace logs. Case events are read from the
serial runner, because SwiftPM's parallel XML writer can hide skipped cases.
Zero executed tests or any skipped test make the result incomplete, never a full
pass.

Two lanes may skip by name, and are listed under `desktop.not_run` with their
reason: `testTwoDisplay*` needs two displays, and
`testPerfOverviewNavigationRenderBudget` runs only with `DEFI_E2E_PERF=1`. They
never count as passed. The report also records the session `restoration` and
the `daemons` count before and after, which must both be exactly one. Visual
inspection is always reported as `not-run`.

</details>

<details>
<summary>What desktop verification does to your Mac</summary>

**Signing.** Without an explicit identity, signing reuses the installed app's
certificate. Installation requires the same certificate and designated
requirement, checked before stopping the daemon. If that key is unavailable,
restore the identity rather than picking another. The checks never reset or
grant privacy permissions.

**Your session.** Before installing, verification stops the daemon to flush and
checkpoint its topology store. After the tests, failures included, it restores
that store with the daemon stopped, restarts it, and checks every monitor's
workspaces, logical focus, column widths, scroll, and window frames. The
checkpoint and the observed restoration stay with the run. Closed windows,
changed monitors, or your own input can prevent exact restoration, which fails
the check instead of passing it. Native focus and visual appearance are not
certified. Session identity uses the boot UUID and audit session ID, so restarts
keep the same topology while another login or boot cannot reuse stale window
identities.

**Installation.** The installer copies and verifies the candidate before
stopping the app, keeps the previous bundle during startup, and restores it if
replacement or startup fails. If a daemon refuses to stop during recovery, it
keeps the backup and reports its path rather than replacing a running bundle.
Debug mode commits the installation before handing control to LLDB.

**The desktop lock.** A per-user file lock serializes installation and desktop
tests. Busy commands exit with code 75, and the OS releases the lock when its
processes exit; never delete the lock file to get around it. With
`desktop --wait`, the command resumes automatically when the desktop frees up,
then rechecks source and bundle hashes; changes during the wait invalidate the
run. Waiting is not first-in, first-out. Cancel with Ctrl-C.

The lock does not stop your own mouse and keyboard, and desktop tests move real
windows, so use a development desktop. For manual checks, hold the reservation
in an interactive shell:

```sh
script/desktop_lock.sh --wait bash
# Install and inspect the app from this shell.
# Restore the original workspace, confirm one daemon, then exit to release the desktop.
```

`make install` and `./script/test_desktop.sh [DesktopE2ETests/testName]` use the
same reservation. The test script restores a previously running service on
success, failure, or interruption.

**Focus fixture.** The owned focus fixture is a normal-level window whose public
`accessibilityPerformRaise()` calls `orderFrontRegardless()` synchronously and
returns success. It raises only at launch or on explicit request. These tests
cover Defi's public raise request against an explicit AXRaise while keeping
native keyboard-delivery assertions. They do not prove that every third-party or
default AppKit window reorders while inactive.

</details>

### Optional: desktop tests in a VM

If your desktop is busy, run `DesktopE2ETests` in a windowless
[Tart](https://github.com/cirruslabs/tart) VM. Nothing requires it, and it does
not replace `verify.sh desktop`.

```sh
tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest defi-e2e
tart set defi-e2e --cpu 4 --memory 4096
script/test_vm.sh                                # or DesktopE2ETests/<test>
```

Plan for about 50 GB of disk and 4 GB of memory while it runs. Runs queue on a
per-VM lock, and `DEFI_VM_SECOND_DISPLAY=1` adds a virtual second display for
the two-display tests.

<details>
<summary>VM details and limits</summary>

The script restarts a VM left running and always stops it at the end, which
frees its memory. If a run is killed outright, use `tart stop defi-e2e`. The VM
runs with `--no-audio`, so alert sounds from test shortcuts stay off your
speakers; pass it too when you start the VM by hand. From the second boot on,
the script disables guest services Defi never touches, such as Siri, iCloud, and
Shortcuts. It also clears the image's boot banner.

The VM runs with SIP disabled, so it cannot certify SIP-enabled behavior, the
signed installed app, real multi-display hardware, or animation quality.
`testTwoDisplayWindowsStayOnTheirDisplay` has been unstable on the virtual
display. Run `verify.sh desktop` for those before a release.

`testFocusFollowsLatestNativeIntent` fails on any desktop while another app's
window with a non-zero alpha sits above the fixtures, because it blocks the
pointer hit test. Notification Center's full-display window blocks only over its
content.

`testPointerResolvesThroughNotificationBannerOverlay` posts one real
notification, the only system surface the desktop tests create. It reports not
run if none appears.

</details>

## Code boundaries

- Keep `DefiModel`, `DefiCore`, `DefiConfig`, `DefiRuntime`, and `DefiIPC`
  independent from AppKit, ApplicationServices, and CoreGraphics.
- Route state mutation through `DefiRuntime`.
- Keep Accessibility writes asynchronous, bounded, and diffed.
- Add deterministic tests for layout, parsing, commands, and state changes.
- Add or run desktop validation for focus, parking, animation, hotkeys, mouse,
  or multi-monitor behavior.

## Pull requests

Use a focused branch with a conventional prefix such as `feat/`, `fix/`,
`docs/`, or `refactor/`. Describe the user-visible change, the tests you ran,
and known limitations. Keep alpha-scope changes small and reversible.

## Configuration migrations

When a change renames or replaces a configuration key, Defi rewrites old files
in place, keeping comments and layout, so users never edit their file by hand:

1. Add a function to `Sources/DefiMacOS/ConfigMigration.swift` that returns the
   rewritten source, or nil when nothing needs migrating, and test it with a
   before/after fixture.
2. Append it to `configMigrations` with `introducedIn` set to the next release
   and `removeIn` two minor releases later.
3. List the old and new keys under **Configuration changes** in the release notes.

A migration only serves files from earlier releases: Defi rewrites the file on
its first launch. `ConfigMigrationTests` fails once `Support/Defi-Info.plist`
reaches a migration's `removeIn`. The release that bumps the version then
deletes the migration and adds each old key to `removedConfigKeys` in
`Sources/DefiConfig/RemovedConfigKeys.swift` with a one-line replacement hint.
A file that still sets a removed key then fails to load with that hint instead
of being silently ignored. Empty `removedConfigKeys` at the first stable release.

## Release packaging

Releases are signed with a stable self-signed certificate and are not notarized.
The Homebrew Cask removes quarantine itself, and `script/install.sh` downloads
with `curl`, which adds none. A DMG downloaded in a browser stays quarantined
until the user clicks Open Anyway in System Settings, as the README explains.

Create the release identity once:

```sh
./script/setup_release_certificate.sh
```

Back up `Defi Release` from Keychain Access to encrypted offline storage. Never
commit the exported private key or attach it to a release. The encrypted export
may only live in a protected GitHub Actions secret for automated signing.

### Automated releases

1. On the branch that bumps the version and build number in
   `Support/Defi-Info.plist`, run `make perf-release` and commit the
   `perf/releases/v<version>.json` and `.md` it writes (see
   [Release performance check](PERFORMANCE.md#release-performance-check)). The
   Release workflow refuses a tag without them.
2. After merging, push a matching tag from `main`, such as `v0.2.2`. The workflow
   checks the version and ancestry, builds, runs the tests, and waits for
   approval of the `release` environment.
3. Inspect the tagged commit, then approve.

The signing job uses a temporary keychain, checks the certificate fingerprint,
packages the app, removes the signing files, and publishes only the ZIP and
checksum. Stable tags then open a PR in `qeude/homebrew-tap` to review and merge
separately; prerelease tags do not update the Cask.

To check signing and packaging without publishing, use **Actions › Release ›
Run workflow** on `main`. A workflow retry cannot overwrite a published release;
a failed draft upload can be retried before publication.

<details>
<summary>Setting up the <code>release</code> environment</summary>

Require a maintainer reviewer, and allow deployments only from `v*` tags and
`main`. Store these environment secrets:

- `DEFI_RELEASE_P12_BASE64`: Base64-encoded encrypted export of the existing
  `Defi Release` certificate **and private key**.
- `DEFI_RELEASE_P12_PASSWORD`: the export password.
- `HOMEBREW_TAP_TOKEN`: a fine-grained token restricted to `qeude/homebrew-tap`,
  with Contents and Pull requests read/write access. Renew it before it expires.

The maintainer can approve their own deployment, so a solo maintainer needs no
second account. The Homebrew job may ask for another approval. If it fails,
rerun only that job: it reads the published checksum and never rebuilds or
replaces the release.

See GitHub's
[certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
and
[environment protection](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
docs.

</details>

<details>
<summary>Packaging by hand</summary>

After the required checks pass, build the non-notarized arm64 ZIP, DMG, and
checksums:

```sh
./script/package_release.sh
```

The script checks the bundle signature and architecture, rejects private key
material, provisioning profiles, personal source paths, and email addresses,
then writes `Defi-v<version>.zip`, `Defi-v<version>.dmg`, and their SHA-256
files under `dist/`. Upload only those four files to the matching release tag.

Then update `qeude/homebrew-tap` with the release URL and SHA-256. The Cask must
install `Defi.app`, expose `Defi.app/Contents/MacOS/defi` through a `binary`
stanza, remove `com.apple.quarantine` in `postflight`, and zap:

- `~/.config/defi`
- `~/Library/Application Support/Defi`
- `~/Library/Caches/com.qeude.defi`
- `~/Library/Caches/com.quentin.defi` (pre-0.5 identifier)
- `~/Library/Logs/Defi`
- `~/Library/Logs/Defi.log`
- `~/Library/Preferences/com.qeude.defi.plist`
- `~/Library/Preferences/com.quentin.defi.plist` (pre-0.5 identifier)
- `~/Library/Saved Application State/com.qeude.defi.savedState`
- `~/Library/Saved Application State/com.quentin.defi.savedState` (pre-0.5 identifier)
- `~/Library/LaunchAgents/com.quentin.defi.plist` (legacy installations)

</details>

> [!WARNING]
> Installed apps update themselves from the release marked latest, and accept a
> download only if it satisfies `defiReleaseRequirement` in
> `Sources/DefiMacOS/AppUpdater.swift`. Rotating the release certificate strands
> every installed copy: change that requirement, the pin in `release.yml`, and
> the one in `script/install.sh` together, and expect users to reinstall by hand.

## Development scripts

| Script | Purpose |
| --- | --- |
| `build_and_run.sh` | Build, sign, install, and launch Defi; `--install-staged` reuses a prepared bundle. |
| `verify.sh` | Local preparation or exclusive desktop verification, with recorded results. |
| `test_desktop.sh` | Stop Defi, run desktop tests, and restore the app. |
| `test_vm.sh` | Run desktop tests in the `defi-e2e` Tart VM. |
| `desktop_lock.sh` | Reserve the desktop across concurrent and nested commands. |
| `desktop_session.sh` | Checkpoint and restore session stores under the desktop reservation. |
| `check_signing.sh` | Compare certificates and designated requirements without changing anything. |
| `resolve_signing_identity.sh` | Pick the signing identity for the build script. |
| `setup_release_certificate.sh` | Create the stable local release certificate. |
| `package_release.sh` | Package the signed app as a ZIP and DMG with checksums. |
| `update_homebrew_release.sh` | Open a Cask update PR from a published release checksum. |
| `install.sh` | The end-user install script the README points to. |
| `perf_release.sh` | Release performance check: previous release against the candidate, in the VM (needs Tart, jq, Python 3). |
| `fluidity_probe.py` | Optional: dropped frames per user action, measured with Instruments (needs Python 3). |

See [PERFORMANCE.md](PERFORMANCE.md) for performance investigation.
