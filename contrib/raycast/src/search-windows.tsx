import { Action, ActionPanel, Color, environment, Icon, Keyboard, List } from "@raycast/api";
import { useCachedState, useFrecencySorting } from "@raycast/utils";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { ErrorView } from "./error-view";
import { workspaceLabel, type DefiWindow } from "./parse";
import { StripDetail } from "./strip-detail";
import { stripColumns } from "./strip";
import { workspaceIcon } from "./workspace-icon";

export default function Command() {
  const desktop = useDesktop();
  const { windows, workspaces, focused, displayCount, appIcon } = desktop;
  const [showStrip, setShowStrip] = useCachedState("show-strip", false);
  // shortcut: ranks windows by picks made here, not by Defi's focus history; use that order once
  // list-windows exposes it (feat/recent-windows-switcher keeps one).
  const { data: ranked, visitItem } = useFrecencySorting(windows, { key: (window) => String(window.id) });
  // The focused window goes last: Enter on it would change nothing.
  const sorted = [...ranked.filter((window) => !window.focused), ...ranked.filter((window) => window.focused)];
  const dark = environment.appearance === "dark";

  const position = (window: DefiWindow) => {
    if (!window.workspace || !window.column) return "Floating";
    const columns = stripColumns(windows ?? [], window.workspace.id);
    const stack = columns[window.column - 1]?.length ?? 1;
    const place = `Column ${window.column} of ${columns.length}`;
    return stack > 1 ? `${place}, row ${window.row} of ${stack}` : place;
  };

  const focus = async (window: DefiWindow, then: string[][] = [], hud?: string) => {
    await visitItem(window);
    await runAndClose([["focus-window-id", String(window.id)], ...then], hud);
  };

  return (
    <List
      isLoading={desktop.isLoading}
      isShowingDetail={showStrip && sorted.length > 0}
      searchBarPlaceholder="Search windows by title, app, or workspace"
    >
      {desktop.error ? (
        <ErrorView error={desktop.error} onRetry={desktop.revalidate} />
      ) : desktop.isLoading ? null : (
        <List.EmptyView
          icon={Icon.Window}
          title={sorted.length ? "No Matching Windows" : "No Managed Windows"}
          description={sorted.length ? "Try an app or a workspace name." : "Defi manages windows once they open."}
        />
      )}
      {sorted.map((window) => {
        const workspace = window.workspace;
        const label = workspace ? workspaceLabel(workspace) : undefined;
        const here = focused?.workspace;
        return (
          <List.Item
            key={window.id}
            icon={appIcon(window.appID) ?? Icon.Window}
            title={window.title || window.appName}
            subtitle={window.title ? window.appName : undefined}
            keywords={[window.appName, ...(label ? [label] : [])]}
            accessories={[
              ...(window.focused ? [{ tag: { value: "Focused", color: Color.Blue } }] : []),
              ...(window.floating ? [{ tag: "Floating" }] : []),
              ...(workspace && label
                ? [
                    {
                      icon: workspaceIcon(workspace),
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
                  <Action title="Focus Window" icon={Icon.Window} onAction={() => focus(window)} />
                  {here && workspace && here.id !== workspace.id ? (
                    <Action
                      title={`Bring to ${workspaceLabel(here)}`}
                      icon={Icon.ArrowDownCircle}
                      shortcut={{ modifiers: ["shift"], key: "return" }}
                      onAction={() =>
                        focus(
                          window,
                          [["move-window-to-workspace-name", here.id]],
                          `${window.appName} → ${workspaceLabel(here)}`,
                        )
                      }
                    />
                  ) : null}
                </ActionPanel.Section>
                <ActionPanel.Section>
                  <ActionPanel.Submenu
                    title="Move to Workspace"
                    icon={Icon.ArrowRight}
                    shortcut={{ modifiers: ["cmd"], key: "m" }}
                  >
                    {workspaces
                      ?.filter((target) => target.id !== workspace?.id)
                      .map((target) => {
                        const name = workspaceLabel(target);
                        return (
                          <Action
                            key={target.id}
                            icon={target.kind === "trailing" ? Icon.Plus : workspaceIcon(target)}
                            title={displayCount > 1 ? `${name} on Display ${target.display}` : name}
                            onAction={() =>
                              focus(
                                window,
                                [["move-window-to-workspace-name", target.id]],
                                `${window.appName} → ${name}`,
                              )
                            }
                          />
                        );
                      })}
                  </ActionPanel.Submenu>
                  <Action
                    title={window.floating ? "Tile Window" : "Float Window"}
                    icon={window.floating ? Icon.AppWindowGrid2x2 : Icon.Layers}
                    shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
                    onAction={() => focus(window, [["toggle-floating"]])}
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
