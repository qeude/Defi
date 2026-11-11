import { Action, ActionPanel, getApplications, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { defi, runAndClose } from "./defi";
import { parseWindows, parseWorkspaces, workspaceLabel } from "./parse";

export default function Command() {
  // list-windows follows layout order; sort by recent use here once feat/recent-windows-switcher exposes it.
  const windows = usePromise(async () => parseWindows(await defi("list-windows", "--json")));
  const workspaces = usePromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")));
  const apps = usePromise(getApplications);
  const appPaths = new Map(apps.data?.map((app) => [app.bundleId, app.path]));
  const displayCount = new Set(workspaces.data?.map((workspace) => workspace.display)).size;

  return (
    <List isLoading={windows.isLoading} searchBarPlaceholder="Search windows by title or app">
      {windows.error ? (
        <List.EmptyView icon={Icon.Warning} title="Cannot read Defi windows" description={windows.error.message} />
      ) : (
        <List.EmptyView icon={Icon.Window} title="No managed windows" />
      )}
      {windows.data?.map((window) => {
        const appPath = window.appID ? appPaths.get(window.appID) : undefined;
        return (
          <List.Item
            key={window.id}
            icon={appPath ? { fileIcon: appPath } : Icon.Window}
            title={window.title || window.appName}
            subtitle={window.title ? window.appName : undefined}
            keywords={[window.appName]}
            accessories={[
              ...(window.workspace ? [{ tag: workspaceLabel(window.workspace) }] : []),
              ...(window.display !== undefined && displayCount > 1 ? [{ text: `Display ${window.display}` }] : []),
            ]}
            actions={
              <ActionPanel>
                <Action
                  title="Focus Window"
                  icon={Icon.Eye}
                  onAction={() => runAndClose(["focus-window-id", String(window.id)])}
                />
                <ActionPanel.Submenu title="Move to Workspace" icon={Icon.ArrowRight}>
                  {workspaces.data
                    ?.filter((workspace) => workspace.id !== window.workspace?.id)
                    .map((workspace) => (
                      <Action
                        key={workspace.id}
                        title={`${workspaceLabel(workspace)}${displayCount > 1 ? ` (Display ${workspace.display})` : ""}`}
                        onAction={() =>
                          runAndClose(
                            ["focus-window-id", String(window.id)],
                            ["move-window-to-workspace-name", workspace.id],
                          )
                        }
                      />
                    ))}
                </ActionPanel.Submenu>
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
