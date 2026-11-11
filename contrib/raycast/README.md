# Raycast extension

Reach Defi's windows, workspaces, and commands from
[Raycast](https://www.raycast.com). The extension only runs the `defi` CLI. It
makes no network calls, so window titles stay on your Mac.

## Install

You need Node.js 22 or later. From the Defi repository root:

```sh
cd contrib/raycast
npm install && npm run dev
```

`npm run dev` adds the extension to Raycast in development mode.

### Tinycast

[Tinycast](https://github.com/abue-ammar/tinycast) runs the built extension.
Build it straight into Tinycast's extensions folder:

```sh
cd contrib/raycast
npm install && npm run tinycast
```

Tinycast reads each command's bundle when the command starts, so after an
update, run `npm run tinycast` again; there is nothing to reinstall.

## Commands

- **Search Windows** finds any window Defi manages by title, app, or
  workspace. Enter focuses it, ⇧↵ brings it to the current workspace, ⌘M moves
  it to another one, and ⌘⇧F floats or tiles it. Windows you pick often come
  first; the focused one comes last.
- **Search Workspaces** lists the workspaces of every display with their apps;
  search by name, number, or app. Enter shows the workspace, ⌘↵ moves the
  focused window there, ⌘⇧↵ sends it without following, and ⌥↵ moves its
  column.
- **Run Command** runs any Defi command, with the ones you ran last on top. The
  search text also works as an argument: `60` sets the column width to 60%,
  `+10` or `-10` widens or narrows it, `960` sets it in points, `2` goes to the
  second workspace, and a workspace name offers to go there or move the focused
  window or column there. It takes the same text as an argument, so `Run
  Command 60` works from the root search. ⌘⇧C copies a command for `[keys]`.
  See [Commands](../../CONFIGURATION.md#commands).

In both searches, ⌘Y shows the workspace's strip, and ⌘R refreshes.

## Finding Defi

The extension uses Defi.app from `/Applications`, then `~/Applications`. If it
lives elsewhere, pick it in **Defi App** in the extension's preferences.

When Defi is not running, Enter launches it. The extension makes no network
calls; window titles stay on your Mac.
