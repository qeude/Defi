import { Action, ActionPanel, Icon, Keyboard, LaunchProps, List } from "@raycast/api";
import { useCachedPromise, useCachedState } from "@raycast/utils";
import { useState } from "react";
import { descriptions, prompts, sections } from "./commands";
import { defi, runAndClose } from "./defi";
import { describeError, RecoveryActions } from "./error-view";
import { parseWorkspaces } from "./parse";
import { formatShortcut } from "./shortcut";
import { suggestions, type Suggestion } from "./suggest";

const entries = sections.flatMap(([section, list]) => list.map((entry) => ({ ...entry, section })));
const recentLimit = 5;

const suggestionIcons: Record<Suggestion["kind"], Icon> = {
  width: Icon.ArrowsExpand,
  height: Icon.ChevronUpDown,
  workspace: Icon.ArrowRight,
  column: Icon.AppWindowSidebarLeft,
  window: Icon.Window,
};

function CommandDetail({ text, command, shortcut }: { text: string; command?: string; shortcut?: string }) {
  return (
    <List.Item.Detail
      markdown={text}
      metadata={
        command ? (
          <List.Item.Detail.Metadata>
            <List.Item.Detail.Metadata.Label title="Command" text={command} />
            <List.Item.Detail.Metadata.Label
              title="Default Shortcut"
              text={shortcut ? formatShortcut(shortcut) : "Unset"}
            />
          </List.Item.Detail.Metadata>
        ) : undefined
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
  const problem = workspaces.error;
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
      subtitle={showDetail ? undefined : entry.command}
      keywords={entry.command.split(/[- ]/)}
      accessories={entry.shortcut ? [{ text: formatShortcut(entry.shortcut), tooltip: "Default shortcut" }] : []}
      detail={
        <CommandDetail
          text={descriptions[entry.command.split(" ")[0]] ?? ""}
          command={entry.command}
          shortcut={entry.shortcut}
        />
      }
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
      searchBarPlaceholder="Search commands, or type 60, +10, 2…"
    >
      {problem ? (
        <List.Section>
          <List.Item
            icon={describeError(problem).icon}
            title={describeError(problem).title}
            keywords={[searchText]}
            detail={<CommandDetail text={describeError(problem).description} />}
            actions={<RecoveryActions error={problem} onRetry={workspaces.revalidate} />}
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
              detail={<CommandDetail text={suggestion.title} command={suggestion.binding} />}
              actions={
                <ActionPanel>
                  <Action
                    title="Run Command"
                    icon={Icon.Play}
                    onAction={() => runAndClose([suggestion.args], suggestion.hud)}
                  />
                  {suggestion.binding ? (
                    <Action.CopyToClipboard
                      title="Copy Command"
                      content={suggestion.binding}
                      shortcut={Keyboard.Shortcut.Common.Copy}
                    />
                  ) : null}
                  {toggleDetail}
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
          {searchText
            ? null
            : prompts
                .filter((prompt) => prompt.section === section)
                .map((prompt) => (
                  <List.Item
                    key={prompt.title}
                    icon={prompt.icon}
                    title={prompt.title}
                    detail={<CommandDetail text={prompt.hint} />}
                    actions={
                      <ActionPanel>
                        <Action
                          title="Insert Example"
                          icon={Icon.TextCursor}
                          onAction={() => setSearchText(prompt.example)}
                        />
                        {toggleDetail}
                      </ActionPanel>
                    }
                  />
                ))}
          {entries.filter((entry) => entry.section === section).map((entry) => item(entry))}
        </List.Section>
      ))}
    </List>
  );
}
