import { Action, ActionPanel, Icon, Keyboard, LaunchProps, List } from "@raycast/api";
import { useCachedPromise, useCachedState } from "@raycast/utils";
import { useState } from "react";
import { descriptions, sections, type Entry } from "./commands";
import { defi, runAndClose } from "./defi";
import { describeError, RecoveryActions } from "./error-view";
import { parseWorkspaces } from "./parse";
import { suggestions, type Suggestion } from "./suggest";

const entries = sections.flatMap(([section, list]) => list.map((entry) => ({ ...entry, section })));
const recentLimit = 5;

const suggestionIcons: Record<Suggestion["kind"], Icon> = {
  width: Icon.ArrowsExpand,
  workspace: Icon.ArrowRight,
  column: Icon.AppWindowSidebarLeft,
  window: Icon.Window,
};

function CommandDetail({ entry }: { entry: Entry }) {
  const description = descriptions[entry.command.split(" ")[0]] ?? "";
  return (
    <List.Item.Detail
      markdown={`## ${entry.title}\n\n${description}`}
      metadata={
        <List.Item.Detail.Metadata>
          <List.Item.Detail.Metadata.Label title="Command" text={entry.command} />
          <List.Item.Detail.Metadata.Label title="Default Shortcut" text={entry.shortcut ?? "None"} />
        </List.Item.Detail.Metadata>
      }
    />
  );
}

export default function Command(props: LaunchProps<{ arguments: Arguments.RunCommand }>) {
  // An empty optional argument arrives as "", so fall through to the root-search text.
  const [searchText, setSearchText] = useState(props.arguments?.query || props.fallbackText || "");
  const [recent, setRecent] = useCachedState<string[]>("recent-commands", []);
  const [showDetail, setShowDetail] = useCachedState("show-command-detail", true);
  const workspaces = useCachedPromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")), [], {
    onError: () => undefined,
  });
  const problem = workspaces.error && describeError(workspaces.error);
  const suggested = suggestions(searchText, workspaces.data ?? []);
  const recentEntries = searchText
    ? []
    : recent.flatMap((command) => entries.filter((entry) => entry.command === command));

  const run = (command: string) => {
    setRecent([command, ...recent.filter((other) => other !== command)].slice(0, recentLimit));
    return runAndClose([command.split(" ")]);
  };

  const toggleDetail = (
    <Action
      title={showDetail ? "Hide Details" : "Show Details"}
      icon={Icon.AppWindowSidebarRight}
      shortcut={Keyboard.Shortcut.Common.ToggleQuickLook}
      onAction={() => setShowDetail(!showDetail)}
    />
  );

  const item = (entry: (typeof entries)[number], keyPrefix = "") => (
    <List.Item
      key={keyPrefix + entry.command}
      icon={entry.icon}
      title={entry.title}
      subtitle={entry.command}
      keywords={entry.command.split(/[- ]/)}
      detail={<CommandDetail entry={entry} />}
      actions={
        <ActionPanel>
          <Action title="Run Command" icon={Icon.Play} onAction={() => run(entry.command)} />
          <Action.CopyToClipboard
            title="Copy Command"
            content={entry.command}
            shortcut={Keyboard.Shortcut.Common.Copy}
          />
          {toggleDetail}
        </ActionPanel>
      }
    />
  );

  return (
    <List
      filtering={{ keepSectionOrder: true }}
      isShowingDetail={showDetail}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder="Search commands, or type 60, +10, 2, or a workspace"
    >
      {problem && workspaces.error ? (
        <List.Section>
          <List.Item
            icon={problem.icon}
            title={problem.title}
            keywords={[searchText]}
            detail={<List.Item.Detail markdown={`## ${problem.title}\n\n${problem.description}`} />}
            actions={<RecoveryActions error={workspaces.error} onRetry={workspaces.revalidate} />}
          />
        </List.Section>
      ) : null}
      {suggested.length > 0 ? (
        <List.Section title="Suggestions">
          {suggested.map((suggestion) => {
            const command = suggestion.args.join(" ");
            return (
              <List.Item
                key={command}
                icon={suggestionIcons[suggestion.kind]}
                title={suggestion.title}
                // Built-in filtering would drop "+10" from "Widen Column by 10%"; the query always matches.
                keywords={[searchText]}
                detail={
                  <List.Item.Detail
                    markdown={`## ${suggestion.title}`}
                    metadata={
                      <List.Item.Detail.Metadata>
                        <List.Item.Detail.Metadata.Label title="Command" text={command} />
                      </List.Item.Detail.Metadata>
                    }
                  />
                }
                actions={
                  <ActionPanel>
                    <Action
                      title="Run Command"
                      icon={Icon.Play}
                      onAction={() => runAndClose([suggestion.args], suggestion.hud)}
                    />
                    <Action.CopyToClipboard
                      title="Copy Command"
                      content={command}
                      shortcut={Keyboard.Shortcut.Common.Copy}
                    />
                    {toggleDetail}
                  </ActionPanel>
                }
              />
            );
          })}
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
