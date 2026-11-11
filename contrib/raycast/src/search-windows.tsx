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

export default function Command() {
  const desktop = useDesktop();
  const { windows, workspaces, focused, displayCount, appIcon } = desktop;
  const [showStrip, setShowStrip] = useCachedState("show-strip", false);
  const [scope, setScope] = useState("");
  // shortcut: ranks windows by picks made here, not by Defi's focus history; use that order once
  // list-windows exposes it (feat/recent-windows-switcher keeps one).
  const { data: ranked, visitItem } = useFrecencySorting(windows, { key: (window) => String(window.id) });
  const scopeID = scope === current ? focused?.workspace?.id : scope;
  const inScope = ranked.filter((window) => !scopeID || window.workspace?.id === scopeID);
  // The focused window goes last: Enter on it would change nothing.
  const sorted = [...inScope.filter((window) => !window.focused), ...inScope.filter((window) => window.focused)];
  const dark = environment.appearance === "dark";
  const here = focused?.workspace;

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

  const scopeMenu = (
    <List.Dropdown tooltip="Show Windows On" value={scope} onChange={setScope}>
      <List.Dropdown.Item title="All Workspaces" value="" icon={Icon.AppWindowGrid3x3} />
      {here ? <List.Dropdown.Item title="Current Workspace" value={current} icon={Icon.Eye} /> : null}
      <List.Dropdown.Section>
        {workspaces
          ?.filter((workspace) => workspace.windowCount > 0)
          .map((workspace) => (
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

  return (
    <List
      isLoading={desktop.isLoading}
      isShowingDetail={showStrip && sorted.length > 0}
      searchBarPlaceholder="Search windows by title, app, or workspace"
      searchBarAccessory={scopeMenu}
    >
      {desktop.error ? (
        <ErrorView error={desktop.error} onRetry={desktop.revalidate} />
      ) : desktop.isLoading ? null : (
        <List.EmptyView
          icon={Icon.Window}
          title={windows?.length ? "No Matching Windows" : "No Windows Yet"}
          description={
            windows?.length ? "Try an app or a workspace name." : "Open an app window and Defi will tile it."
          }
        />
      )}
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
            accessories={[
              ...(window.focused ? [{ tag: { value: "Focused", color: Color.Blue } }] : []),
              ...(window.floating ? [{ tag: "Floating" }] : []),
              ...(fullWorkspace && label
                ? [
                    {
                      icon: workspaceIcon(fullWorkspace),
                      text: label,
                      tooltip: displayCount > 1 ? `${label} on display ${window.display}` : label,
                    },
                  ]
                : []),
            ]}
            detail={
              workspace ? (
                <StripDetail
                  windows={windows ?? []}
                  workspaceID={workspace.id}
                  highlightID={window.id}
                  dark={dark}
                  appIcon={appIcon}
                >
                  <List.Item.Detail.Metadata.Label title="Workspace" text={label} />
                  {displayCount > 1 ? (
                    <List.Item.Detail.Metadata.Label title="Display" text={String(window.display)} />
                  ) : null}
                  <List.Item.Detail.Metadata.Label title="Position" text={position(window)} />
                  <List.Item.Detail.Metadata.Separator />
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
                      onAction={() =>
                        act(
                          window,
                          [["move-window-to-workspace-name", here.id]],
                          `Brought ${window.appName} to ${workspaceLabel(here)}`,
                        )
                      }
                    />
                  ) : null}
                  <Action
                    title={window.floating ? "Tile Window" : "Float Window"}
                    icon={window.floating ? Icon.AppWindowGrid2x2 : Icon.Layers}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                    onAction={() => act(window, [["toggle-floating"]])}
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
                    title={showStrip ? "Hide Strip" : "Show Strip"}
                    icon={Icon.AppWindowSidebarRight}
                    shortcut={Keyboard.Shortcut.Common.ToggleQuickLook}
                    onAction={() => setShowStrip(!showStrip)}
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
