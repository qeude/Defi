import { Action, ActionPanel, environment, getApplications, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { defi, runAndClose } from "./defi";
import { ErrorView } from "./error-view";
import { parseWindows, parseWorkspaces, workspaceLabel, type DefiWindow } from "./parse";
import { escapeMarkdown, stripMarkdown } from "./strip";

export default function Command() {
  // list-windows follows layout order; sort by recent use here once feat/recent-windows-switcher exposes it.
  const windows = usePromise(async () => parseWindows(await defi("list-windows", "--json")));
  const workspaces = usePromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")));
  const apps = usePromise(getApplications);
  const appPaths = new Map(apps.data?.map((app) => [app.bundleId, app.path]));
  const displayCount = new Set(workspaces.data?.map((workspace) => workspace.display)).size;
  const dark = environment.appearance === "dark";
  const where = (window: DefiWindow) =>
    [window.workspace && workspaceLabel(window.workspace), displayCount > 1 && `Display ${window.display}`]
      .filter(Boolean)
      .join(" · ");

  const detail = (window: DefiWindow) =>
    [
      `## ${escapeMarkdown(window.appName)}`,
      window.title && window.title !== window.appName ? escapeMarkdown(window.title) : "",
      window.workspace ? stripMarkdown(windows.data ?? [], window.workspace.id, window.id, dark) : "",
      where(window),
    ]
      .filter(Boolean)
      .join("\n\n");

  return (
    <List
      isLoading={windows.isLoading}
      isShowingDetail={Boolean(windows.data?.length)}
      searchBarPlaceholder="Search windows by title, app, or workspace"
    >
      {windows.error ? (
        <ErrorView title="Cannot read Defi windows" error={windows.error} />
      ) : (
        <List.EmptyView icon={Icon.Window} title="No managed windows" />
      )}
      {windows.data?.length ? (
        <List.Item
          key="previous"
          icon={Icon.Undo}
          title="Previous Window"
          detail={
            <List.Item.Detail markdown="Go back to the window focused before this one, on any workspace or display." />
          }
          actions={
            <ActionPanel>
              <Action
                title="Focus Previous Window"
                icon={Icon.Undo}
                onAction={() => runAndClose([["focus-window-previous"]])}
              />
            </ActionPanel>
          }
        />
      ) : null}
      {windows.data?.map((window) => {
        const appPath = window.appID ? appPaths.get(window.appID) : undefined;
        return (
          <List.Item
            key={window.id}
            icon={appPath ? { fileIcon: appPath } : Icon.Window}
            title={window.title || window.appName}
            keywords={[window.appName, ...(window.workspace ? [workspaceLabel(window.workspace)] : [])]}
            accessories={[
              ...(window.focused ? [{ icon: Icon.CircleFilled, tooltip: "Focused window" }] : []),
              ...(window.workspace ? [{ tag: workspaceLabel(window.workspace) }] : []),
            ]}
            detail={<List.Item.Detail markdown={detail(window)} />}
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
                  {workspaces.data
                    ?.filter((workspace) => workspace.id !== window.workspace?.id)
                    .map((workspace) => {
                      const label = workspaceLabel(workspace);
                      return (
                        <Action
                          key={workspace.id}
                          title={displayCount > 1 ? `${label} (Display ${workspace.display})` : label}
                          onAction={() =>
                            runAndClose(
                              [
                                ["focus-window-id", String(window.id)],
                                ["move-window-to-workspace-name", workspace.id],
                              ],
                              `${window.appName} → ${label}`,
                            )
                          }
                        />
                      );
                    })}
                </ActionPanel.Submenu>
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
