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

- **Search Windows** lists Defi's managed windows with their app, workspace, and
  display. Enter focuses the window. **Move to Workspace** sends it to another
  workspace and follows it there.
- **Search Workspaces** lists the workspaces of every display. Enter shows the
  workspace. Other actions move the focused window or column there.
- **Run Command** runs a Defi command without arguments: focus, moves, widths,
  stacks, the Overview, the cheatsheet, and Settings. See
  [Commands](../../CONFIGURATION.md#commands).

## Finding Defi

The extension looks for `defi` in `/Applications/Defi.app`, then
`~/Applications/Defi.app`. If Defi lives elsewhere, set **Defi CLI Path** in the
extension's preferences.

When Defi is not running or its JSON format is newer than the extension, the
lists stay empty and show the reason.
