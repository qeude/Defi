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

- **Search Windows** lists Defi's managed windows by workspace. Search by
  title, app, or workspace. Enter focuses the window; ⌘M moves it to another
  workspace and follows it.
- **Search Workspaces** lists the workspaces of every display with the apps on
  each. Enter shows the workspace, ⌘↵ moves the focused window there, and ⌥↵
  moves the focused column.
- **Run Command** runs a Defi command, most used first. The search text also
  works as an argument: `60` sets the column width to 60%, `+10` or `-10` widens
  or narrows it, `960` sets it in points, `3` goes to workspace 3, and a
  workspace name offers to go there or move the focused column or window there.
  See [Commands](../../CONFIGURATION.md#commands).

In both searches, ⌘D shows the workspace's strip beside the list.

## Finding Defi

The extension looks for `defi` in `/Applications/Defi.app`, then
`~/Applications/Defi.app`. If Defi lives elsewhere, set **Defi CLI Path** in the
extension's preferences.

When Defi is not running or its JSON format is newer than the extension, the
lists stay empty and show the reason; when Defi is not running, Enter launches
it.
