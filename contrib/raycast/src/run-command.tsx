import { Action, ActionPanel, Icon, Keyboard, LaunchProps, List } from "@raycast/api";
import { useCachedPromise, useCachedState } from "@raycast/utils";
import { useState } from "react";
import { defi, notRunning, runAndClose } from "./defi";
import { RecoveryActions } from "./error-view";
import { parseWorkspaces } from "./parse";
import { suggestions, type Suggestion } from "./suggest";

type Entry = { command: string; title: string; icon: Icon };

// Argument-free forms of the commands in CONFIGURATION.md, "Commands".
const sections: [string, Entry[]][] = [
  [
    "Focus",
    [
      { command: "focus-column left", title: "Focus Left Column", icon: Icon.ArrowLeft },
      { command: "focus-column right", title: "Focus Right Column", icon: Icon.ArrowRight },
      { command: "focus-column first", title: "Focus First Column", icon: Icon.ArrowLeftCircle },
      { command: "focus-column last", title: "Focus Last Column", icon: Icon.ArrowRightCircle },
      { command: "focus-window up", title: "Focus Window Above", icon: Icon.ArrowUp },
      { command: "focus-window down", title: "Focus Window Below", icon: Icon.ArrowDown },
      { command: "focus-window first", title: "Focus Top Window", icon: Icon.ArrowUpCircle },
      { command: "focus-window last", title: "Focus Bottom Window", icon: Icon.ArrowDownCircle },
      { command: "focus-window-previous", title: "Focus Previous Window", icon: Icon.Undo },
      { command: "focus-window-or-workspace up", title: "Focus Window or Workspace Above", icon: Icon.ArrowUp },
      { command: "focus-window-or-workspace down", title: "Focus Window or Workspace Below", icon: Icon.ArrowDown },
      { command: "focus-column-or-monitor left", title: "Focus Left Column or Display", icon: Icon.ArrowLeft },
      { command: "focus-column-or-monitor right", title: "Focus Right Column or Display", icon: Icon.ArrowRight },
      { command: "focus-floating previous", title: "Focus Previous Floating Window", icon: Icon.ChevronLeft },
      { command: "focus-floating next", title: "Focus Next Floating Window", icon: Icon.ChevronRight },
      { command: "focus-floating first", title: "Focus First Floating Window", icon: Icon.ArrowLeftCircle },
      { command: "focus-floating last", title: "Focus Last Floating Window", icon: Icon.ArrowRightCircle },
      { command: "activate-floating", title: "Bring Floating Windows Forward", icon: Icon.Layers },
      { command: "focus-monitor left", title: "Focus Left Display", icon: Icon.Monitor },
      { command: "focus-monitor right", title: "Focus Right Display", icon: Icon.Monitor },
      { command: "focus-monitor up", title: "Focus Display Above", icon: Icon.Monitor },
      { command: "focus-monitor down", title: "Focus Display Below", icon: Icon.Monitor },
    ],
  ],
  [
    "Workspaces",
    [
      { command: "focus-workspace up", title: "Focus Workspace Above", icon: Icon.ChevronUp },
      { command: "focus-workspace down", title: "Focus Workspace Below", icon: Icon.ChevronDown },
      { command: "focus-workspace-previous", title: "Focus Previous Workspace", icon: Icon.Undo },
      { command: "reorder-workspace up", title: "Move Workspace Up", icon: Icon.ArrowUp },
      { command: "reorder-workspace down", title: "Move Workspace Down", icon: Icon.ArrowDown },
      { command: "move-workspace-to-monitor left", title: "Move Workspace to Left Display", icon: Icon.Monitor },
      { command: "move-workspace-to-monitor right", title: "Move Workspace to Right Display", icon: Icon.Monitor },
      { command: "move-workspace-to-monitor up", title: "Move Workspace to Display Above", icon: Icon.Monitor },
      { command: "move-workspace-to-monitor down", title: "Move Workspace to Display Below", icon: Icon.Monitor },
    ],
  ],
  [
    "Move",
    [
      { command: "move-column left", title: "Move Column Left", icon: Icon.ArrowLeft },
      { command: "move-column right", title: "Move Column Right", icon: Icon.ArrowRight },
      { command: "move-column first", title: "Move Column to Start", icon: Icon.ArrowLeftCircle },
      { command: "move-column last", title: "Move Column to End", icon: Icon.ArrowRightCircle },
      { command: "move-window up", title: "Move Window Up", icon: Icon.ArrowUp },
      { command: "move-window down", title: "Move Window Down", icon: Icon.ArrowDown },
      { command: "move-column-to-workspace up", title: "Move Column to Workspace Above", icon: Icon.ChevronUp },
      { command: "move-column-to-workspace down", title: "Move Column to Workspace Below", icon: Icon.ChevronDown },
      { command: "move-window-to-workspace up", title: "Move Window to Workspace Above", icon: Icon.ChevronUp },
      { command: "move-window-to-workspace down", title: "Move Window to Workspace Below", icon: Icon.ChevronDown },
      { command: "send-column-to-workspace up", title: "Send Column to Workspace Above", icon: Icon.ArrowNe },
      { command: "send-column-to-workspace down", title: "Send Column to Workspace Below", icon: Icon.ArrowNe },
      { command: "send-window-to-workspace up", title: "Send Window to Workspace Above", icon: Icon.ArrowNe },
      { command: "send-window-to-workspace down", title: "Send Window to Workspace Below", icon: Icon.ArrowNe },
      { command: "move-column-or-to-monitor left", title: "Move Column Left or to Display", icon: Icon.ArrowLeft },
      { command: "move-column-or-to-monitor right", title: "Move Column Right or to Display", icon: Icon.ArrowRight },
      { command: "move-column-to-monitor left", title: "Move Column to Left Display", icon: Icon.Monitor },
      { command: "move-column-to-monitor right", title: "Move Column to Right Display", icon: Icon.Monitor },
      { command: "move-column-to-monitor up", title: "Move Column to Display Above", icon: Icon.Monitor },
      { command: "move-column-to-monitor down", title: "Move Column to Display Below", icon: Icon.Monitor },
      { command: "move-window-to-monitor left", title: "Move Window to Left Display", icon: Icon.Monitor },
      { command: "move-window-to-monitor right", title: "Move Window to Right Display", icon: Icon.Monitor },
      { command: "move-window-to-monitor up", title: "Move Window to Display Above", icon: Icon.Monitor },
      { command: "move-window-to-monitor down", title: "Move Window to Display Below", icon: Icon.Monitor },
    ],
  ],
  [
    "Size and Stacks",
    [
      { command: "cycle-width next", title: "Next Column Width", icon: Icon.ArrowsExpand },
      { command: "cycle-width previous", title: "Previous Column Width", icon: Icon.ArrowsContract },
      { command: "maximize-column", title: "Maximize Column", icon: Icon.Maximize },
      { command: "expand-column-to-available-width", title: "Fill Available Width", icon: Icon.ArrowsExpand },
      { command: "center-column", title: "Center Column", icon: Icon.Center },
      { command: "center-visible-columns", title: "Center Visible Columns", icon: Icon.AlignCentre },
      { command: "switch-preset-window-height", title: "Next Window Height", icon: Icon.ChevronUpDown },
      { command: "reset-window-height", title: "Reset Window Heights", icon: Icon.RotateAntiClockwise },
      { command: "join-window left", title: "Stack Into Left Column", icon: Icon.AppWindowList },
      { command: "join-window right", title: "Stack Into Right Column", icon: Icon.AppWindowList },
      { command: "unjoin-windows", title: "Unstack Window", icon: Icon.AppWindowGrid2x2 },
      { command: "consume-or-expel-window left", title: "Stack or Unstack Left", icon: Icon.AppWindowSidebarLeft },
      { command: "consume-or-expel-window right", title: "Stack or Unstack Right", icon: Icon.AppWindowSidebarRight },
      { command: "swap-window left", title: "Swap With Left Window", icon: Icon.Switch },
      { command: "swap-window right", title: "Swap With Right Window", icon: Icon.Switch },
      { command: "toggle-floating", title: "Toggle Floating", icon: Icon.Window },
    ],
  ],
  [
    "Defi",
    [
      { command: "toggle-overview", title: "Toggle Overview", icon: Icon.AppWindowGrid3x3 },
      { command: "toggle-cheatsheet", title: "Toggle Cheatsheet", icon: Icon.Keyboard },
      { command: "open-settings", title: "Open Settings", icon: Icon.Gear },
      { command: "diagnostic-mark", title: "Mark a Problem for Diagnostics", icon: Icon.Bug },
    ],
  ],
];

const entries = sections.flatMap(([section, list]) => list.map((entry) => ({ ...entry, section })));
const recentLimit = 5;

const suggestionIcons: Record<Suggestion["kind"], Icon> = {
  width: Icon.ArrowsExpand,
  workspace: Icon.ArrowRight,
  column: Icon.AppWindowSidebarLeft,
  window: Icon.Window,
};

export default function Command(props: LaunchProps<{ arguments: Arguments.RunCommand }>) {
  const [searchText, setSearchText] = useState(props.arguments?.query ?? props.fallbackText ?? "");
  const [recent, setRecent] = useCachedState<string[]>("recent-commands", []);
  const workspaces = useCachedPromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")), [], {
    onError: () => undefined,
  });
  const suggested = suggestions(searchText, workspaces.data ?? []);
  const recentEntries = searchText
    ? []
    : recent.flatMap((command) => entries.filter((entry) => entry.command === command));

  const run = (command: string) => {
    setRecent([command, ...recent.filter((other) => other !== command)].slice(0, recentLimit));
    return runAndClose([command.split(" ")]);
  };

  const item = (entry: (typeof entries)[number], keyPrefix = "") => (
    <List.Item
      key={keyPrefix + entry.command}
      icon={entry.icon}
      title={entry.title}
      subtitle={entry.command}
      keywords={entry.command.split(/[- ]/)}
      actions={
        <ActionPanel>
          <Action title="Run Command" icon={Icon.Play} onAction={() => run(entry.command)} />
          <Action.CopyToClipboard
            title="Copy Command"
            content={entry.command}
            shortcut={Keyboard.Shortcut.Common.Copy}
          />
        </ActionPanel>
      }
    />
  );

  return (
    <List
      filtering={{ keepSectionOrder: true }}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Search commands, or type 60, +10, 2, or a workspace"
    >
      {workspaces.error?.message === notRunning ? (
        <List.Section>
          <List.Item
            icon={Icon.Power}
            title="Defi Is Not Running"
            subtitle="Launch it to run commands"
            keywords={[searchText]}
            actions={<RecoveryActions error={workspaces.error} onRetry={workspaces.revalidate} />}
          />
        </List.Section>
      ) : null}
      {suggested.length > 0 ? (
        <List.Section title="Suggestions">
          {suggested.map((suggestion) => (
            <List.Item
              key={suggestion.args.join(" ")}
              icon={suggestionIcons[suggestion.kind]}
              title={suggestion.title}
              // Built-in filtering would drop "+10" from "Widen Column by 10%"; the query always matches.
              keywords={[searchText]}
              actions={
                <ActionPanel>
                  <Action
                    title="Run Command"
                    icon={Icon.Play}
                    onAction={() => runAndClose([suggestion.args], suggestion.hud)}
                  />
                </ActionPanel>
              }
            />
          ))}
        </List.Section>
      ) : null}
      {recentEntries.length > 0 ? (
        <List.Section title="Recent">{recentEntries.map((entry) => item(entry, "recent-"))}</List.Section>
      ) : null}
      {sections.map(([section]) => (
        <List.Section key={section} title={section}>
          {entries.filter((entry) => entry.section === section).map((entry) => item(entry))}
        </List.Section>
      ))}
    </List>
  );
}
