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

[Tinycast](https://github.com/abue-ammar/tinycast) runs the built extension:

```sh
cd contrib/raycast
npm install && npm run build
```

In Tinycast, open Settings > Extensions > Install New > Add from folder and
pick `contrib/raycast/dist`. Tinycast copies the folder, so after an update,
build and add it again.

## Commands

- **Search Windows** lists Defi's managed windows. Search by title, app, or
  workspace. The side pane shows where the window sits in its workspace's strip.
  Enter focuses it; **Previous Window**, at the top, goes back to the window
  focused before. ⌘M moves the window to another workspace and follows it.
- **Search Workspaces** lists the workspaces of every display, each with its
  strip. Enter shows the workspace. Other actions move the focused window or
  column there.
- **Run Command** runs a Defi command, most used first. The search text also
  works as an argument: `60` sets the column width to 60%, `+10` or `-10` widens
  or narrows it, `960` sets it in points, `3` goes to workspace 3, and a
  workspace name offers to go there or move the focused column or window there.
  See [Commands](../../CONFIGURATION.md#commands).

## Finding Defi

The extension looks for `defi` in `/Applications/Defi.app`, then
`~/Applications/Defi.app`. If Defi lives elsewhere, set **Defi CLI Path** in the
extension's preferences.

When Defi is not running or its JSON format is newer than the extension, the
lists stay empty and show the reason; when Defi is not running, Enter launches
it.
