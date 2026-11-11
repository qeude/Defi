import { Action, ActionPanel, Icon, Keyboard, LaunchProps, List } from "@raycast/api";
import { useCachedState } from "@raycast/utils";
import { useState } from "react";
import { descriptions, prompts, sections } from "./commands";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { describeError, RecoveryActions } from "./error-view";
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

// What a row does; Default Shortcut appears where Defi binds one or for a command that has none.
function CommandDetail({ text, command, shortcut }: { text: string; command?: string; shortcut?: string | null }) {
  return (
    <List.Item.Detail
      markdown={text}
      metadata={
        command ? (
          <List.Item.Detail.Metadata>
            <List.Item.Detail.Metadata.Label title="Command" text={command} />
            {shortcut !== undefined ? (
              <List.Item.Detail.Metadata.Label
                title="Default Shortcut"
                text={shortcut ? formatShortcut(shortcut) : "None"}
              />
            ) : null}
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
  const desktop = useDesktop();
  const problem = desktop.error;
  const suggested = suggestions(searchText, problem ? [] : (desktop.workspaces ?? []));
  const recentEntries = searchText
    ? []
    : recent.flatMap((command) => entries.filter((entry) => entry.command === command));

  const run = (entry: (typeof entries)[number]) => {
    setRecent([entry.command, ...recent.filter((other) => other !== entry.command)].slice(0, recentLimit));
    return runAndClose([entry.command.split(" ")], entry.hud);
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
      icon={Icon[entry.icon]}
      title={entry.title}
      subtitle={showDetail ? undefined : entry.command}
      keywords={entry.command.split(/[- ]/)}
      // The side pane shows the shortcut, so rows next to it stay bare.
      accessories={
        !showDetail && entry.shortcut ? [{ text: formatShortcut(entry.shortcut), tooltip: "Default shortcut" }] : []
      }
      detail={
        <CommandDetail
          text={descriptions[entry.command.split(" ")[0]] ?? ""}
          command={entry.command}
          shortcut={entry.shortcut ?? null}
        />
      }
      actions={
        <ActionPanel>
          <Action title="Run Command" icon={Icon.Play} onAction={() => run(entry)} />
          <Action.CopyToClipboard title="Copy Command" content={entry.command} />
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
            actions={<RecoveryActions error={problem} onRetry={desktop.revalidate} />}
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
              detail={
                <CommandDetail
                  text={suggestion.description}
                  command={suggestion.binding}
                  shortcut={suggestion.shortcut}
                />
              }
              actions={
                <ActionPanel>
                  <Action
                    title="Run Command"
                    icon={Icon.Play}
                    onAction={() => runAndClose([suggestion.args], suggestion.hud)}
                  />
                  {/* Copy keeps ⌘↵ on every row; without a [keys] form, it copies the CLI call. */}
                  <Action.CopyToClipboard
                    title="Copy Command"
                    content={suggestion.binding ?? `defi ${suggestion.args.join(" ")}`}
                  />
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
          {/* Example rows stay findable by search, and step aside once the search is itself an argument. */}
          {suggested.length > 0
            ? null
            : prompts
                .filter((prompt) => prompt.section === section)
                .map((prompt) => (
                  <List.Item
                    key={prompt.title}
                    icon={Icon[prompt.icon]}
                    title={prompt.title}
                    keywords={prompt.keywords}
                    detail={<CommandDetail text={prompt.hint} />}
                    actions={
                      <ActionPanel>
                        <Action
                          title="Insert Example"
                          icon={Icon.TextCursor}
                          onAction={() => setSearchText(prompt.example)}
                        />
                        <Action.CopyToClipboard title="Copy Command" content={prompt.syntax} />
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
