# Service lifecycle and single instance

## Sub-features

- `defi service enable|disable|start|stop|restart|status`.
- Per-user instance lock before the IPC socket.
- Session store persistence across restart.

## How to get to it (user POV)

Login item, or `defi service ...`.

## Driving it with the defi CLI

```sh
defi list-workspaces --json > before.json
defi service restart; sleep 5
pgrep -u "$(id -u)" -x defi-daemon | wc -l
defi list-workspaces --json > after.json
diff <(jq -S .monitors before.json) <(jq -S .monitors after.json) && echo same
```

Pass: one daemon, `status` reachable, workspace identity and order preserved.

## Gotchas

- Use `defi service restart`, never `open -n`.
- Restart interrupts any in-flight animation; do not run it during a Computer Use session you care about.
- Replacing the bundle needs the desktop reservation and an unchanged designated requirement.
