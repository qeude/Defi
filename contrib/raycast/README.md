# Raycast extension

Reach [Defi](https://github.com/qeude/Defi), the scrolling-columns window
manager for macOS, from [Raycast](https://www.raycast.com) or
[Tinycast](https://github.com/abue-ammar/tinycast). The extension only runs the
`defi` command line tool inside Defi.app and makes no network calls, so window
titles stay on your Mac.

## Commands

- **Search Windows** finds any window Defi manages by title, app, or
  workspace, and the dropdown narrows it to one workspace. Enter focuses the
  window, ⌘↵ moves it to another workspace, ⇧↵ brings it to the current one,
  and ⌘⇧F floats or tiles it. Windows you pick often come first; the focused
  one comes last. Acting on a window from another workspace shows that
  workspace for a moment, because Defi focuses the window first.
- **Search Workspaces** lists the workspaces of every display with their apps
  and strip; search by name, number, or app. Enter goes to the workspace. ⌘↵
  moves the focused window there, ⌘⇧↵ sends it without following, and ⌥↵ and
  ⌥⇧↵ do the same with its column. ⌘O lists the workspace's windows.
- **Search Commands** runs any Defi command, with the ones you ran last on top.
  The side pane says what each one does, and the row shows its default
  shortcut. The search text also works as an argument: `60` sets the column
  width to 60%, `+10` or `-10` changes it, `960` sets it in points, `h50` sets a
  stacked window's height, `2` goes to the second workspace, and a workspace
  name offers to go there or move the focused window or column there. Type the
  same text after the command in the root search, as in `Search Commands 60`.
  ⌘↵ copies a command in the form `[keys]` accepts. See
  [Commands](https://github.com/qeude/Defi/blob/main/CONFIGURATION.md#commands).

⌘Y shows or hides the side pane, and ⌘R reloads a list.
Shortcuts shown are Defi's defaults, with `mod` as ⌃⌥; your own `[keys]` may
differ.

## Install

You need Node.js 22 or later and Defi.app. From the Defi repository root:

```sh
cd contrib/raycast
npm install && npm run dev
```

`npm run dev` adds the extension to Raycast in development mode. For Tinycast,
run `npm run tinycast` instead: it builds straight into Tinycast's extensions
folder, and Tinycast picks up a new build the next time a command starts.

## Troubleshooting

- **Defi Is Not Installed**: the extension looks for Defi.app in
  `/Applications`, then `~/Applications`. If it lives elsewhere, pick it in
  **Defi App** in the extension's preferences.
- **Defi Is Not Running**: press Enter to launch it; the list fills in once
  Defi starts.
- **Update Defi** or **Update This Extension**: Defi and the extension read
  different versions of the JSON format. Update the older one; a newer
  extension is rebuilt from this folder.
