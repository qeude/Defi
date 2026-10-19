# Virtual workspaces and parking

## Sub-features

- Named persistent workspaces from `[workspaces].names`, dynamic ordinary ones.
- Per-monitor workspace stacks.
- Inactive workspace windows parked offscreen through topology and Accessibility.
- Move column or window to a workspace or monitor.

## How to get to it (user POV)

Workspace hotkeys, the menu bar item, or the CLI.

## Driving it with the defi CLI

```sh
defi list-workspaces --json > workspaces-before.json
defi focus-workspace-name web; sleep 1
defi status | tr ' ' '\n' | grep -E '^(workspace|hidden|visibility|drift)='
defi focus-workspace-name dev      # restore the recorded initial workspace
```

Pass: `workspace=` equals the target, `hidden=` equals the parked window count, `drift=0[]`, and the JSON `active` flag moved.

## Gotchas

- Names depend on the user's config; read them from `list-workspaces --json` first.
- `--monitor <n>` is 1-based display index, while `id` in JSON is the monitor ID.
- Always restore the initial workspace.
- Covering tests: `testFocusedWindowRemainsResolvableWhileParkedOffscreen`, `testUnhiddenOnePixelStripAnchorConvergesWithRealWindowFrame`.
