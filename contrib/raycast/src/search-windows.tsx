import { Action, ActionPanel, environment, Icon, List } from "@raycast/api";
import { useCachedState } from "@raycast/utils";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { ErrorView } from "./error-view";
import { workspaceLabel, type DefiWindow } from "./parse";
import { stripColumns, stripImage } from "./strip";
import { workspaceIcon } from "./workspace-icon";

export default function Command() {
  const { windows, workspaces, isLoading, error, displayCount, appIcon } = useDesktop();
  const [showStrip, setShowStrip] = useCachedState("show-strip", false);
  const dark = environment.appearance === "dark";

  // list-windows follows layout order; sort by recent use here once feat/recent-windows-switcher exposes it.
  const sections = new Map<string, DefiWindow[]>();
  for (const window of windows ?? []) {
    const key = window.workspace?.id ?? "";
    sections.set(key, [...(sections.get(key) ?? []), window]);
  }

  const position = (window: DefiWindow) => {
    if (!window.workspace || !window.column) return "Floating";
    const columns = stripColumns(windows ?? [], window.workspace.id);
    const stack = columns[window.column - 1]?.length ?? 1;
    const place = `Column ${window.column} of ${columns.length}`;
    return stack > 1 ? `${place}, window ${window.row} of ${stack}` : place;
  };

  return (
    <List
      isLoading={isLoading}
      isShowingDetail={showStrip}
      searchBarPlaceholder="Search windows by title, app, or workspace"
    >
      {error ? (
        <ErrorView title="Cannot read Defi windows" error={error} />
      ) : (
        <List.EmptyView icon={Icon.Window} title="No managed windows" />
      )}
      {[...sections].map(([key, sectionWindows]) => {
        const workspace = sectionWindows[0].workspace;
        const display = sectionWindows[0].display;
        return (
          <List.Section
            key={key}
            title={workspace ? workspaceLabel(workspace) : "No Workspace"}
            subtitle={displayCount > 1 ? `Display ${display}` : undefined}
          >
            {sectionWindows.map((window) => (
              <List.Item
                key={window.id}
                icon={appIcon(window.appID) ?? Icon.Window}
                title={window.title || window.appName}
                subtitle={window.title ? window.appName : undefined}
                keywords={[window.appName, ...(workspace ? [workspaceLabel(workspace)] : [])]}
                accessories={window.focused ? [{ text: "Current" }] : []}
                detail={
                  <List.Item.Detail
                    markdown={workspace ? stripImage(windows ?? [], workspace.id, window.id, dark) : ""}
                    metadata={
                      <List.Item.Detail.Metadata>
                        <List.Item.Detail.Metadata.Label
                          title="App"
                          text={window.appName}
                          icon={appIcon(window.appID)}
                        />
                        {window.title ? <List.Item.Detail.Metadata.Label title="Title" text={window.title} /> : null}
                        <List.Item.Detail.Metadata.Separator />
                        {workspace ? (
                          <List.Item.Detail.Metadata.Label title="Workspace" text={workspaceLabel(workspace)} />
                        ) : null}
                        {displayCount > 1 ? (
                          <List.Item.Detail.Metadata.Label title="Display" text={String(display)} />
                        ) : null}
                        <List.Item.Detail.Metadata.Label title="Position" text={position(window)} />
                      </List.Item.Detail.Metadata>
                    }
                  />
                }
                actions={
                  <ActionPanel>
                    <Action
                      title="Focus Window"
                      icon={Icon.Eye}
                      onAction={() => runAndClose([["focus-window-id", String(window.id)]])}
                    />
                    <ActionPanel.Submenu
                      title="Move to Workspace"
                      icon={Icon.ArrowRight}
                      shortcut={{ modifiers: ["cmd"], key: "m" }}
                    >
                      {workspaces
                        ?.filter((target) => target.id !== window.workspace?.id)
                        .map((target) => {
                          const label = workspaceLabel(target);
                          return (
                            <Action
                              key={target.id}
                              icon={workspaceIcon(target)}
                              title={displayCount > 1 ? `${label} on Display ${target.display}` : label}
                              onAction={() =>
                                runAndClose(
                                  [
                                    ["focus-window-id", String(window.id)],
                                    ["move-window-to-workspace-name", target.id],
                                  ],
                                  `${window.appName} → ${label}`,
                                )
                              }
                            />
                          );
                        })}
                    </ActionPanel.Submenu>
                    <Action
                      title={showStrip ? "Hide Strip" : "Show Strip"}
                      icon={Icon.AppWindowSidebarRight}
                      shortcut={{ modifiers: ["cmd"], key: "d" }}
                      onAction={() => setShowStrip(!showStrip)}
                    />
                  </ActionPanel>
                }
              />
            ))}
          </List.Section>
        );
      })}
    </List>
  );
}
