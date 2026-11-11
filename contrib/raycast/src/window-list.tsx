import { Action, ActionPanel, Color, environment, Icon, Keyboard, List } from "@raycast/api";
import { useCachedState, useFrecencySorting } from "@raycast/utils";
import { useState } from "react";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { ErrorView } from "./error-view";
import { workspaceLabel, type DefiWindow } from "./parse";
import { StripDetail } from "./strip-detail";
import { stripColumns } from "./strip";
import { workspaceIcon } from "./workspace-icon";

const current = "current";

// The window switcher; with workspaceID it lists that workspace only, as Search Workspaces opens it.
export function WindowList({ initialSearch = "", workspaceID }: { initialSearch?: string; workspaceID?: string }) {
  const desktop = useDesktop();
  const { windows, workspaces, displayCount, appIcon, current: here } = desktop;
  const [searchText, setSearchText] = useState(initialSearch);
  const [showDetail, setShowDetail] = useCachedState("windows-strip", false);
  // Every launch starts on all workspaces, so a narrowed list never surprises.
  const [chosenScope, setScope] = useState("");
  const withWindows = workspaces?.filter((workspace) => workspace.windowCount > 0) ?? [];
  const scope = workspaceID ?? chosenScope;
  // shortcut: ranks windows by picks made here, not by Defi's focus history, and keeps the ranks of
  // closed windows; use Defi's order once list-windows exposes it (feat/recent-windows-switcher keeps one).
  const { data: ranked, visitItem } = useFrecencySorting(windows, { key: (window) => String(window.id) });
  const scopeID = scope === current ? here?.id : scope;
  const scopeName = workspaces?.find((workspace) => workspace.id === scopeID);
  // Cached rows would look live while Defi is unreachable, so an error hides them.
  const inScope = desktop.error ? [] : ranked.filter((window) => !scopeID || window.workspace?.id === scopeID);
  // The focused window goes last: Enter on it would change nothing.
  const sorted = [...inScope.filter((window) => !window.focused), ...inScope.filter((window) => window.focused)];
  const dark = environment.appearance === "dark";

  const position = (window: DefiWindow) => {
    if (!window.workspace || !window.column) return "Floating";
    const columns = stripColumns(windows ?? [], window.workspace.id);
    const stack = columns[window.column - 1]?.length ?? 1;
    const place = `Column ${window.column} of ${columns.length}`;
    return stack > 1 ? `${place}, row ${window.row} of ${stack}` : place;
  };

  // shortcut: acting on a window first focuses it, which shows its workspace; a CLI command
  // that takes a window ID would avoid that switch.
  const act = async (window: DefiWindow, then: string[][] = [], hud?: string) => {
    await visitItem(window);
    await runAndClose([["focus-window-id", String(window.id)], ...then], hud);
  };

  const scopeMenu = workspaceID ? undefined : (
    <List.Dropdown tooltip="Show Windows On" value={scope} onChange={setScope}>
      <List.Dropdown.Item title="All Workspaces" value="" icon={Icon.AppWindowGrid3x3} />
      {here ? <List.Dropdown.Item title="Current Workspace" value={current} icon={Icon.Eye} /> : null}
      <List.Dropdown.Section>
        {withWindows.map((workspace) => (
          <List.Dropdown.Item
            key={workspace.id}
            title={
              displayCount > 1
                ? `${workspaceLabel(workspace)} on Display ${workspace.display}`
                : workspaceLabel(workspace)
            }
            value={workspace.id}
            icon={workspaceIcon(workspace)}
          />
        ))}
      </List.Dropdown.Section>
    </List.Dropdown>
  );

  const emptyView = () => {
    if (desktop.error) return <ErrorView error={desktop.error} onRetry={desktop.revalidate} />;
    if (desktop.isLoading) return null;
    if (scopeID && !searchText) {
      const label = scopeName ? workspaceLabel(scopeName) : "This Workspace";
      return (
        <List.EmptyView
          icon={Icon.Window}
          title={`No Windows on ${label}`}
          actions={
            workspaceID ? undefined : (
              <ActionPanel>
                <Action title="Show All Workspaces" icon={Icon.AppWindowGrid3x3} onAction={() => setScope("")} />
              </ActionPanel>
            )
          }
        />
      );
    }
    return (
      <List.EmptyView
        icon={Icon.Window}
        title={windows?.length ? "No Matching Windows" : "No Windows Yet"}
        description={windows?.length ? "Try an app or a workspace name." : "Open an app window and Defi will tile it."}
      />
    );
  };

  return (
    <List
      isLoading={desktop.isLoading}
      isShowingDetail={showDetail && sorted.length > 0}
      navigationTitle={workspaceID && scopeName ? `Windows on ${workspaceLabel(scopeName)}` : undefined}
      searchBarPlaceholder="Search windows by title, app, or workspace"
      searchBarAccessory={scopeMenu}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      filtering
    >
      {emptyView()}
      {sorted.map((window) => {
        const workspace = window.workspace;
        const label = workspace ? workspaceLabel(workspace) : undefined;
        const fullWorkspace = workspaces?.find((candidate) => candidate.id === workspace?.id);
        return (
          <List.Item
            key={window.id}
            icon={appIcon(window.appID) ?? Icon.Window}
            title={window.title || window.appName}
            subtitle={window.title ? window.appName : undefined}
            keywords={[
              window.appName,
              ...(label ? [label] : []),
              ...(window.floating ? ["floating"] : []),
              ...(displayCount > 1 ? [`display ${window.display}`] : []),
            ]}
            // Rows next to the side pane stay bare; the pane carries the same facts.
            accessories={
              showDetail
                ? undefined
                : [
                    ...(window.focused ? [{ tag: { value: "Focused", color: Color.Blue } }] : []),
                    ...(window.floating ? [{ tag: "Floating" }] : []),
                    ...(fullWorkspace && label
                      ? [
                          {
                            icon: workspaceIcon(fullWorkspace),
                            text: label,
                            tooltip: displayCount > 1 ? `${label} on Display ${window.display}` : label,
                          },
                        ]
                      : []),
                  ]
            }
            detail={
              workspace ? (
                <StripDetail
                  windows={windows ?? []}
                  workspaceID={workspace.id}
                  highlightID={window.id}
                  dark={dark}
                  appIcon={appIcon}
                  empty=""
                >
                  <List.Item.Detail.Metadata.Label title="App" text={window.appName} icon={appIcon(window.appID)} />
                  <List.Item.Detail.Metadata.Label title="Workspace" text={label} />
                  {displayCount > 1 ? (
                    <List.Item.Detail.Metadata.Label title="Display" text={String(window.display)} />
                  ) : null}
                  <List.Item.Detail.Metadata.Label title="Position" text={position(window)} />
                  {window.focused || window.floating ? (
                    <List.Item.Detail.Metadata.TagList title="Status">
                      {window.focused ? (
                        <List.Item.Detail.Metadata.TagList.Item text="Focused" color={Color.Blue} />
                      ) : null}
                      {window.floating ? <List.Item.Detail.Metadata.TagList.Item text="Floating" /> : null}
                    </List.Item.Detail.Metadata.TagList>
                  ) : null}
                </StripDetail>
              ) : undefined
            }
            actions={
              <ActionPanel>
                <ActionPanel.Section>
                  <Action title="Focus Window" icon={Icon.Window} onAction={() => act(window)} />
                  <ActionPanel.Submenu title="Move to Workspace" icon={Icon.ArrowRight}>
                    {workspaces
                      ?.filter((target) => target.id !== workspace?.id)
                      .map((target) => {
                        const name = workspaceLabel(target);
                        return (
                          <Action
                            key={target.id}
                            icon={workspaceIcon(target)}
                            title={displayCount > 1 ? `${name} on Display ${target.display}` : name}
                            onAction={() =>
                              act(
                                window,
                                [["move-window-to-workspace-name", target.id]],
                                `Moved ${window.appName} to ${name}`,
                              )
                            }
                          />
                        );
                      })}
                  </ActionPanel.Submenu>
                  {here && workspace && here.id !== workspace.id ? (
                    <Action
                      title={`Bring to ${workspaceLabel(here)}`}
                      icon={Icon.ArrowDownCircle}
                      shortcut={{ modifiers: ["shift"], key: "return" }}
                      onAction={async () => {
                        // The cached current workspace may be stale while the list reloads.
                        const latest = (await desktop.fresh()).workspaces.find((w) => w.active && w.focusedDisplay);
                        const target = latest && latest.id !== workspace.id ? latest : undefined;
                        await act(
                          window,
                          target ? [["move-window-to-workspace-name", target.id]] : [],
                          target ? `Brought ${window.appName} to ${workspaceLabel(target)}` : undefined,
                        );
                      }}
                    />
                  ) : null}
                  <Action
                    title={window.floating ? "Tile Window" : "Float Window"}
                    icon={window.floating ? Icon.AppWindowGrid2x2 : Icon.Layers}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                    onAction={() =>
                      act(window, [["toggle-floating"]], `${window.floating ? "Tiled" : "Floated"} ${window.appName}`)
                    }
                  />
                </ActionPanel.Section>
                <ActionPanel.Section>
                  <Action.CopyToClipboard
                    title="Copy Window Title"
                    content={window.title || window.appName}
                    shortcut={Keyboard.Shortcut.Common.Copy}
                  />
                  <Action.CopyToClipboard
                    title="Copy Window ID"
                    content={String(window.id)}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "i" }}
                  />
                </ActionPanel.Section>
                <ActionPanel.Section>
                  <Action
                    title={showDetail ? "Hide Details" : "Show Details"}
                    icon={Icon.AppWindowSidebarRight}
                    shortcut={Keyboard.Shortcut.Common.ToggleQuickLook}
                    onAction={() => setShowDetail(!showDetail)}
                  />
                  <Action
                    title="Refresh"
                    icon={Icon.ArrowClockwise}
                    shortcut={Keyboard.Shortcut.Common.Refresh}
                    onAction={desktop.revalidate}
                  />
                </ActionPanel.Section>
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
