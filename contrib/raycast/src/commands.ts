import { Icon } from "@raycast/api";

export type Entry = { command: string; title: string; icon: Icon; shortcut?: string };

// Commands that take a value, offered as rows that put an example in the search bar.
export const prompts: { section: string; title: string; icon: Icon; example: string; hint: string }[] = [
  {
    section: "Workspaces",
    title: "Go to Workspace…",
    icon: Icon.ArrowRight,
    example: "1",
    hint: "Type a workspace's number or the start of its name.",
  },
  {
    section: "Widths and Stacks",
    title: "Set Column Width…",
    icon: Icon.ArrowsExpand,
    example: "60",
    hint: "Type a width: 60 for 60%, +10 or -10 to change it, or 960 for points.",
  },
  {
    section: "Widths and Stacks",
    title: "Set Window Height…",
    icon: Icon.ChevronUpDown,
    example: "h50",
    hint: "Type h and a height for the focused stacked window: h50, h+10, or h-10.",
  },
];

// What each command does, from CONFIGURATION.md "Commands".
export const descriptions: Record<string, string> = {
  "focus-column": "Focus the previous, next, first, or last column.",
  "focus-window": "Focus another window in the focused column's stack.",
  "focus-window-previous": "Go back to the window focused before this one, on any workspace or display.",
  "focus-window-or-workspace":
    "Like Focus Window, but past the top or bottom of the stack, focus the adjacent workspace.",
  "focus-column-or-monitor": "Like Focus Column, but past the first or last column, focus the next display.",
  "focus-floating": "Focus another floating window, wrapping around.",
  "activate-floating": "Select the floating layer and bring its selected window forward.",
  "focus-monitor": "Focus the nearest display in that direction.",
  "focus-workspace": "Focus the adjacent workspace on this display, without wrapping.",
  "focus-workspace-previous": "Go back to the workspace this display showed before.",
  "reorder-workspace": "Move the active workspace up or down its display's stack.",
  "move-workspace-to-monitor": "Move the active workspace to another display and remember it there.",
  "move-column": "Move the focused column within the strip.",
  "move-window": "Move the focused window within its stack.",
  "move-column-to-workspace": "Move the focused column to the adjacent workspace and follow it.",
  "move-window-to-workspace": "Move only the focused window to the adjacent workspace and follow it.",
  "send-column-to-workspace": "Move the focused column to the adjacent workspace without following it.",
  "send-window-to-workspace": "Move only the focused window to the adjacent workspace without following it.",
  "move-column-to-monitor": "Move the focused column to the nearest display in that direction.",
  "move-column-or-to-monitor": "Like Move Column, but past the first or last column, move it to the next display.",
  "move-window-to-monitor": "Move only the focused window to the nearest display in that direction.",
  "cycle-width": "Step through the preset column widths, wrapping.",
  "maximize-column": "Toggle the focused column between full width and its previous width.",
  "expand-column-to-available-width":
    "Grow the focused column into the free space beside the other fully visible columns.",
  "center-column": "Center the focused column until you select another one.",
  "center-visible-columns": "Center the fully visible columns as one group.",
  "switch-preset-window-height": "Give the focused stacked window the next preset height, wrapping.",
  "reset-window-height": "Split the focused stack evenly again.",
  "join-window": "Add the focused window to the stack on the left or right.",
  "unjoin-windows": "Split the focused window out of its stack into a new column.",
  "consume-or-expel-window":
    "Alone in its column, the window joins the stack on that side; in a stack, it leaves as a new column.",
  "swap-window": "Swap the focused window with the one at the same row of the adjacent column.",
  "toggle-floating": "Switch the focused window between tiled and floating.",
  "toggle-overview": "Open or close the Overview of every workspace.",
  "toggle-cheatsheet": "Open or close the shortcut help.",
  "open-settings": "Open Defi's Settings, even with the menu bar item hidden.",
  "diagnostic-mark": "Record the current status and recent trace for a bug report, without changing any window.",
};

// Argument-free forms of the commands; shortcuts are Defi's built-in defaults.
export const sections: [string, Entry[]][] = [
  [
    "Focus",
    [
      { command: "focus-column left", title: "Focus Left Column", icon: Icon.ArrowLeft, shortcut: "mod-left" },
      { command: "focus-column right", title: "Focus Right Column", icon: Icon.ArrowRight, shortcut: "mod-right" },
      { command: "focus-column first", title: "Focus First Column", icon: Icon.ArrowLeftCircle, shortcut: "mod-home" },
      { command: "focus-column last", title: "Focus Last Column", icon: Icon.ArrowRightCircle, shortcut: "mod-end" },
      { command: "focus-window up", title: "Focus Window Above", icon: Icon.ArrowUp, shortcut: "mod-up" },
      { command: "focus-window down", title: "Focus Window Below", icon: Icon.ArrowDown, shortcut: "mod-down" },
      { command: "focus-window first", title: "Focus Top Window", icon: Icon.ArrowUpCircle },
      { command: "focus-window last", title: "Focus Bottom Window", icon: Icon.ArrowDownCircle },
      { command: "focus-window-previous", title: "Focus Previous Window", icon: Icon.Undo },
      { command: "focus-window-or-workspace up", title: "Focus Window or Workspace Above", icon: Icon.ArrowUp },
      { command: "focus-window-or-workspace down", title: "Focus Window or Workspace Below", icon: Icon.ArrowDown },
      { command: "focus-column-or-monitor left", title: "Focus Left Column or Display", icon: Icon.ArrowLeft },
      { command: "focus-column-or-monitor right", title: "Focus Right Column or Display", icon: Icon.ArrowRight },
      {
        command: "focus-floating previous",
        title: "Focus Previous Floating Window",
        icon: Icon.ChevronLeft,
        shortcut: "mod-shift-comma",
      },
      {
        command: "focus-floating next",
        title: "Focus Next Floating Window",
        icon: Icon.ChevronRight,
        shortcut: "mod-shift-period",
      },
      { command: "focus-floating first", title: "Focus First Floating Window", icon: Icon.ArrowLeftCircle },
      { command: "focus-floating last", title: "Focus Last Floating Window", icon: Icon.ArrowRightCircle },
      {
        command: "activate-floating",
        title: "Bring Floating Windows Forward",
        icon: Icon.Layers,
        shortcut: "mod-shift-v",
      },
      ...(["left", "right", "up", "down"] as const).map((direction) => ({
        command: `focus-monitor ${direction}`,
        title: `Focus ${displayName(direction)}`,
        icon: Icon.Monitor,
        shortcut: `mod-shift-${direction}`,
      })),
    ],
  ],
  [
    "Workspaces",
    [
      { command: "focus-workspace up", title: "Focus Workspace Above", icon: Icon.ChevronUp, shortcut: "mod-i" },
      { command: "focus-workspace down", title: "Focus Workspace Below", icon: Icon.ChevronDown, shortcut: "mod-u" },
      { command: "focus-workspace-previous", title: "Focus Previous Workspace", icon: Icon.Undo },
      { command: "reorder-workspace up", title: "Move Workspace Up", icon: Icon.ArrowUp, shortcut: "mod-shift-i" },
      {
        command: "reorder-workspace down",
        title: "Move Workspace Down",
        icon: Icon.ArrowDown,
        shortcut: "mod-shift-u",
      },
      ...(["left", "right", "up", "down"] as const).map((direction) => ({
        command: `move-workspace-to-monitor ${direction}`,
        title: `Move Workspace to ${displayName(direction)}`,
        icon: Icon.Monitor,
      })),
    ],
  ],
  [
    "Move",
    [
      { command: "move-column left", title: "Move Column Left", icon: Icon.ArrowLeft, shortcut: "mod-cmd-left" },
      { command: "move-column right", title: "Move Column Right", icon: Icon.ArrowRight, shortcut: "mod-cmd-right" },
      {
        command: "move-column first",
        title: "Move Column to Start",
        icon: Icon.ArrowLeftCircle,
        shortcut: "mod-cmd-home",
      },
      {
        command: "move-column last",
        title: "Move Column to End",
        icon: Icon.ArrowRightCircle,
        shortcut: "mod-cmd-end",
      },
      { command: "move-window up", title: "Move Window Up", icon: Icon.ArrowUp, shortcut: "mod-cmd-up" },
      { command: "move-window down", title: "Move Window Down", icon: Icon.ArrowDown, shortcut: "mod-cmd-down" },
      {
        command: "move-column-to-workspace up",
        title: "Move Column to Workspace Above",
        icon: Icon.ChevronUp,
        shortcut: "mod-cmd-i",
      },
      {
        command: "move-column-to-workspace down",
        title: "Move Column to Workspace Below",
        icon: Icon.ChevronDown,
        shortcut: "mod-cmd-u",
      },
      { command: "move-window-to-workspace up", title: "Move Window to Workspace Above", icon: Icon.ChevronUp },
      { command: "move-window-to-workspace down", title: "Move Window to Workspace Below", icon: Icon.ChevronDown },
      { command: "send-column-to-workspace up", title: "Send Column to Workspace Above", icon: Icon.ArrowNe },
      { command: "send-column-to-workspace down", title: "Send Column to Workspace Below", icon: Icon.ArrowNe },
      { command: "send-window-to-workspace up", title: "Send Window to Workspace Above", icon: Icon.ArrowNe },
      { command: "send-window-to-workspace down", title: "Send Window to Workspace Below", icon: Icon.ArrowNe },
      ...(["left", "right", "up", "down"] as const).map((direction) => ({
        command: `move-column-to-monitor ${direction}`,
        title: `Move Column to ${displayName(direction)}`,
        icon: Icon.Monitor,
        shortcut: `mod-shift-cmd-${direction}`,
      })),
      { command: "move-column-or-to-monitor left", title: "Move Column Left or to Display", icon: Icon.ArrowLeft },
      { command: "move-column-or-to-monitor right", title: "Move Column Right or to Display", icon: Icon.ArrowRight },
      ...(["left", "right", "up", "down"] as const).map((direction) => ({
        command: `move-window-to-monitor ${direction}`,
        title: `Move Window to ${displayName(direction)}`,
        icon: Icon.Monitor,
      })),
    ],
  ],
  [
    "Widths and Stacks",
    [
      { command: "cycle-width next", title: "Next Column Width", icon: Icon.ArrowsExpand, shortcut: "mod-equal" },
      {
        command: "cycle-width previous",
        title: "Previous Column Width",
        icon: Icon.ArrowsContract,
        shortcut: "mod-minus",
      },
      { command: "maximize-column", title: "Maximize Column", icon: Icon.Maximize, shortcut: "mod-f" },
      { command: "expand-column-to-available-width", title: "Fill Available Width", icon: Icon.ArrowsExpand },
      { command: "center-column", title: "Center Column", icon: Icon.Center, shortcut: "mod-c" },
      { command: "center-visible-columns", title: "Center Visible Columns", icon: Icon.AlignCentre },
      { command: "switch-preset-window-height", title: "Next Window Height", icon: Icon.ChevronUpDown },
      { command: "reset-window-height", title: "Reset Window Heights", icon: Icon.RotateAntiClockwise },
      {
        command: "join-window left",
        title: "Stack into Left Column",
        icon: Icon.AppWindowList,
        shortcut: "mod-semicolon",
      },
      {
        command: "join-window right",
        title: "Stack into Right Column",
        icon: Icon.AppWindowList,
        shortcut: "mod-quote",
      },
      { command: "unjoin-windows", title: "Unstack Window", icon: Icon.AppWindowGrid2x2, shortcut: "mod-period" },
      {
        command: "consume-or-expel-window left",
        title: "Stack or Unstack Left",
        icon: Icon.AppWindowSidebarLeft,
        shortcut: "mod-leftbracket",
      },
      {
        command: "consume-or-expel-window right",
        title: "Stack or Unstack Right",
        icon: Icon.AppWindowSidebarRight,
        shortcut: "mod-rightbracket",
      },
      { command: "swap-window left", title: "Swap with Left Window", icon: Icon.Switch },
      { command: "swap-window right", title: "Swap with Right Window", icon: Icon.Switch },
      { command: "toggle-floating", title: "Float or Tile Window", icon: Icon.Window, shortcut: "mod-v" },
    ],
  ],
  [
    "Other",
    [
      { command: "toggle-overview", title: "Toggle Overview", icon: Icon.AppWindowGrid3x3, shortcut: "mod-o" },
      { command: "toggle-cheatsheet", title: "Toggle Cheatsheet", icon: Icon.Keyboard, shortcut: "mod-shift-slash" },
      { command: "open-settings", title: "Open Settings", icon: Icon.Gear },
      { command: "diagnostic-mark", title: "Mark a Problem for Diagnostics", icon: Icon.Bug },
    ],
  ],
];

function cap(word: string) {
  return word[0].toUpperCase() + word.slice(1);
}

function displayName(direction: "left" | "right" | "up" | "down") {
  if (direction === "left" || direction === "right") return `${cap(direction)} Display`;
  return `Display ${direction === "up" ? "Above" : "Below"}`;
}
