import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { useFrecencySorting, usePromise } from "@raycast/utils";
import { useState } from "react";
import { defi, runAndClose } from "./defi";
import { parseWorkspaces } from "./parse";
import { suggestions } from "./suggest";

// Argument-free forms of the commands in CONFIGURATION.md, "Commands".
const sections: [string, string[]][] = [
  [
    "Focus",
    [
      "focus-column left",
      "focus-column right",
      "focus-column first",
      "focus-column last",
      "focus-window up",
      "focus-window down",
      "focus-window first",
      "focus-window last",
      "focus-window-previous",
      "focus-floating previous",
      "focus-floating next",
      "activate-floating",
      "focus-monitor left",
      "focus-monitor right",
      "focus-monitor up",
      "focus-monitor down",
    ],
  ],
  [
    "Workspaces",
    [
      "focus-workspace up",
      "focus-workspace down",
      "focus-workspace-previous",
      "reorder-workspace up",
      "reorder-workspace down",
      "move-workspace-to-monitor left",
      "move-workspace-to-monitor right",
      "move-workspace-to-monitor up",
      "move-workspace-to-monitor down",
    ],
  ],
  [
    "Move Columns and Windows",
    [
      "move-column left",
      "move-column right",
      "move-column first",
      "move-column last",
      "move-window up",
      "move-window down",
      "move-column-to-workspace up",
      "move-column-to-workspace down",
      "move-window-to-workspace up",
      "move-window-to-workspace down",
      "move-column-to-monitor left",
      "move-column-to-monitor right",
      "move-column-to-monitor up",
      "move-column-to-monitor down",
      "move-window-to-monitor left",
      "move-window-to-monitor right",
      "move-window-to-monitor up",
      "move-window-to-monitor down",
    ],
  ],
  [
    "Widths and Stacks",
    [
      "cycle-width previous",
      "cycle-width next",
      "maximize-column",
      "expand-column-to-available-width",
      "center-column",
      "center-visible-columns",
      "switch-preset-window-height",
      "reset-window-height",
      "join-window left",
      "join-window right",
      "unjoin-windows",
      "consume-or-expel-window left",
      "consume-or-expel-window right",
      "swap-window left",
      "swap-window right",
      "toggle-floating",
    ],
  ],
  ["Other", ["toggle-overview", "toggle-cheatsheet", "open-settings"]],
];

const title = (command: string) =>
  command.replace(/(^|[- ])(\w)/g, (_, gap, letter) => (gap && " ") + letter.toUpperCase());

const commands = sections.flatMap(([section, list]) => list.map((command) => ({ id: command, section })));

export default function Command() {
  const [searchText, setSearchText] = useState("");
  const workspaces = usePromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")));
  const { data: sorted, visitItem } = useFrecencySorting(commands);

  return (
    <List
      filtering
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Search commands, or type 60, +10, or a workspace"
    >
      <List.Section title="Suggestions">
        {suggestions(searchText, workspaces.data ?? []).map((suggestion) => (
          <List.Item
            key={suggestion.args.join(" ")}
            icon={Icon.Wand}
            title={suggestion.title}
            subtitle={suggestion.args.join(" ")}
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
      <List.Section title="Commands">
        {sorted.map((item) => (
          <List.Item
            key={item.id}
            icon={Icon.Terminal}
            title={title(item.id)}
            subtitle={item.id}
            keywords={[item.id]}
            accessories={[{ text: item.section }]}
            actions={
              <ActionPanel>
                <Action
                  title="Run Command"
                  icon={Icon.Play}
                  onAction={async () => {
                    await visitItem(item);
                    await runAndClose([item.id.split(" ")]);
                  }}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );
}
