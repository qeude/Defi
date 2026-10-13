---
name: verify-defi
description: Launch, drive and prove behavior of Defi, the macOS scrolling-columns window manager (defi-daemon plus the defi CLI). Use after any change to runtime, layout, overview, focus, parking or config to get evidence from the real daemon, not just unit tests.
---

# Verify Defi

Defi is a per-user macOS daemon (`defi-daemon`) controlled by the `defi` CLI over a Unix socket. There is no web or simulator surface. The real surface is the installed daemon on the user's desktop, driven by `defi` commands and read back through `defi status`, `defi trace` and `defi list-workspaces --json`. Visual behavior needs Computer Use.

Rules that override convenience (from `AGENTS.md`):

- Exactly one `defi-daemon` per user session. Never `open -n`, never start a second binary by hand.
- You cannot run an isolated second instance. The instance lock is per user. Drive the one installed daemon, or stop it and replace it through the scripts below.
- Installation and desktop tests share one per-user desktop reservation. Scripts acquire it and exit 75 when busy.
- Restore the user's workspace and confirm one daemon before you finish.

## Which tier to use

| Change | Tier | Command |
| --- | --- | --- |
| Docs only | none | check the diff |
| Code, tests, build config | local | `python3 script/verify.py local` |
| Daemon wiring, platform integration, desktop-visible | stage + desktop | `python3 script/verify.py local --stage` then `python3 script/verify.py desktop dist/verification/<run> --wait [--filter DesktopE2ETests/<test>]` |
| Animation, focus, parking, hotkeys, Dock/Command-Tab, overview visuals | all of the above plus live drive | sections below |

`verify.py local` never installs and forces `DEFI_E2E=0`. `desktop` installs the exact staged bundle, runs XCTest, and restores the session store. Zero executed or skipped tests count as incomplete, not pass.

## Launch

The installed app is the unit under test. To put your change into it:

```sh
python3 script/verify.py local --stage          # prints dist/verification/<run>
python3 script/verify.py desktop dist/verification/<run> --wait
```

Signing must keep the installed designated requirement or macOS re-prompts for Accessibility and Screen Recording. If the identity is missing, set `DEFI_CODESIGN_IDENTITY` in the ignored `.env.local`. Do not choose another certificate.

Restart the installed build with `defi service restart`. Ready means `defi status` prints `running session=active` and `pgrep -x defi-daemon | wc -l` is 1.

## Doctor

```sh
.agents/skills/verify-defi/doctor.sh
```

Read-only. Prints daemon count, binary path and start time, session state, overview permission, preview counters, and which `defi` is first on `PATH`. Run it first, and again whenever behavior looks wrong. A daemon that has been up for many hours and reports `overviewReceivedPreviews=0` after an overview open is a wedged daemon, not a passing one.

## Drive

Commands are plain CLI calls. Useful, real ones:

```sh
defi toggle-overview                       # open or close the overview
defi focus-column left|right|first|last
defi focus-workspace up|down
defi focus-workspace-name dev              # names come from list-workspaces
defi focus-workspace-position 2
defi move-column left|right|first|last
defi cycle-width next|prev
defi --monitor 2 focus-workspace-name web
defi list-workspaces --json
defi status                                # one line of key=value counters
defi trace                                 # recent timestamped runtime events
```

Note `defi workspace 2` selects a workspace by ID, not by position, so the daemon answers `unknown workspace: 2`. Use `focus-workspace-position` for a position.

Parse `defi status` by splitting on spaces and grepping `key=`. Do not scrape by column.

For real human timing, hotkeys and mouse behavior, hold the desktop reservation in an interactive shell (`python3 script/desktop_lock.py --wait bash`) and use Computer Use. Synthetic command bursts alone do not certify native focus or animation quality.

## Evidence

Write evidence under `dist/verification/evidence-<yyyymmdd-hhmmss>/` (ignored by git, survives cleanup):

- `before.status`, `after.status` from `defi status`
- `trace.log` from `defi trace` covering the action
- `workspaces-before.json`, `workspaces-after.json` from `list-workspaces --json`
- screenshots from Computer Use for visual claims
- `/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.qeude.defi"'` for logger output. In zsh `log` is a builtin, so call `/usr/bin/log`.

Proof standard: drive the user path (CLI command or real hotkey), capture the state before and after, and check the side effect in `status` counters or `list-workspaces`. A passing unit test is not proof of a desktop-visible change. For anything visual, correlate the screenshot with `status` and `trace`.

## Cleanup

1. Close any overview you opened (`defi toggle-overview` only if `overview=open`).
2. Restore the initial workspace you recorded in `before.status` with `defi focus-workspace-name <name>`.
3. Restore any config file you edited from your backup. Never leave `~/.config/defi/config.toml` changed.
4. Exit the `desktop_lock.py` shell if you opened one.
5. Run the doctor and confirm exactly one daemon.

Keep the evidence directory.

## Feature map

See `features/README.md`. A proof that drives one entry point is incomplete when the map lists others.
