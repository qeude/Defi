---
name: Bug report
about: Report something that does not work as expected. Run `defi triage` first, it often solves the problem.
labels: bug
---

## Before you file

Run `defi triage` in Terminal, or choose **Start Triage** under **Settings >
About**. Your own coding agent (Claude Code or Codex) investigates on your Mac
and asks you what it needs. It often solves the problem on the spot. Otherwise
it drafts this report for you to copy here, with the evidence needed to fix it
and your private information removed. It changes nothing on your Mac and posts
nothing without your approval.

- [ ] I ran `defi triage` and pasted its report below, in place of the sections
      that follow.
- [ ] I could not run `defi triage`, so I filled in the sections below.

## What happened?

Describe the problem and what you expected instead.

## Steps to reproduce

1.
2.
3.

Does it happen every time or occasionally?

## Setup

- Defi version and installation method:
- macOS version and Mac model:
- Affected apps and versions:
- Monitors, scaling, and arrangement:
- Accessibility permission granted: yes / no
- Other window managers or keyboard remappers running:

## Visual glitches

For flicker, jumps, or windows that look wrong for a moment:

- Does it still happen with **Settings > Appearance > Animation > Enable
  animations** turned off?
- Screen recordings leave Defi's animations out. Turn on **Settings > General >
  Diagnostics > Show animations in screen recordings** before you record, and
  turn it off afterwards.

## Diagnostics, if useful

Include only the config entries needed to reproduce the problem. Run
`defi diagnostic-mark` right after the problem happens. It saves what Defi saw
without changing your windows. Then quote only the relevant lines of
`defi status` or the newest marker in `~/Library/Logs/Defi/Diagnostics/`, with
the approximate time and your time zone. Do not attach whole files. The README
explains how to run the bundled CLI without Homebrew.

<!-- Issues are public. Review logs, config, screenshots, and recordings before
posting. Remove private window titles, file paths, workspace names, tokens,
and any other personal or work information. -->
