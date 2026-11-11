import { Action, ActionPanel, Color, environment, Icon, Keyboard, List, showHUD } from "@raycast/api";
import { useCachedState } from "@raycast/utils";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { ErrorView } from "./error-view";
import { workspaceLabel, type DefiWorkspace } from "./parse";
import { StripDetail } from "./strip-detail";
import { workspaceIcon } from "./workspace-icon";

const maxAppIcons = 5;

export default function Command() {
  const desktop = useDesktop();
  const { windows, workspaces, focused, displayCount, appIcon, appName } = desktop;
  const [showStrip, setShowStrip] = useCachedState("show-strip", false);
  const dark = environment.appearance === "dark";
  const displays = [...new Set(workspaces?.map((workspace) => workspace.display))];
  const moving = focused?.appName ?? "Focused Window";

  const actions = (workspace: DefiWorkspace, label: string) => {
    const elsewhere = focused !== undefined && focused.workspace?.id !== workspace.id;
    // The secondary action keeps ⌘↵ on every row, so it stays even where it has nothing to move.
    const moveHere = () =>
      elsewhere
        ? runAndClose([["move-window-to-workspace-name", workspace.id]], `Moved ${moving} to ${label}`)
        : showHUD(focused ? `${moving} is already on ${label}` : "No window is focused");
    return (
      <ActionPanel>
        <ActionPanel.Section>
          <Action
            title={`Go to ${label}`}
            icon={Icon.ArrowRight}
            onAction={() => runAndClose([["--monitor", String(workspace.display), "workspace", workspace.id]])}
          />
          <Action title={`Move ${moving} Here`} icon={Icon.Window} onAction={moveHere} />
          {elsewhere ? (
            <>
              <Action
                title={`Send ${moving} Here`}
                icon={Icon.ArrowNe}
                shortcut={{ modifiers: ["cmd", "shift"], key: "return" }}
                onAction={() =>
                  runAndClose([["send-window-to-workspace-name", workspace.id]], `Sent ${moving} to ${label}`)
                }
              />
              <Action
                title="Move Column Here"
                icon={Icon.AppWindowSidebarLeft}
                shortcut={{ modifiers: ["opt"], key: "return" }}
                onAction={() =>
                  runAndClose([["move-column-to-workspace-name", workspace.id]], `Moved column to ${label}`)
                }
              />
            </>
          ) : null}
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
    );
  };

  return (
    <List
      isLoading={desktop.isLoading}
      isShowingDetail={showStrip && Boolean(workspaces?.length)}
      searchBarPlaceholder="Search workspaces by name, number, or app"
    >
      {desktop.error ? (
        <ErrorView error={desktop.error} onRetry={desktop.revalidate} />
      ) : desktop.isLoading ? null : (
        <List.EmptyView icon={Icon.AppWindowGrid3x3} title="No Matching Workspaces" description="Try an app name." />
      )}
      {displays.map((display) => {
        const onDisplay = workspaces?.filter((workspace) => workspace.display === display) ?? [];
        return (
          <List.Section
            key={display}
            title={displayCount > 1 ? `Display ${display}` : undefined}
            subtitle={displayCount > 1 && onDisplay[0]?.focusedDisplay ? "Focused" : undefined}
          >
            {onDisplay.map((workspace) => {
              const label = workspaceLabel(workspace);
              const icons = workspace.applications.map((app) => ({
                icon: appIcon(app) ?? Icon.AppWindow,
                tooltip: appName(app),
              }));
              const extra = icons.length - maxAppIcons;
              return (
                <List.Item
                  key={workspace.id}
                  icon={workspaceIcon(workspace, workspace.active)}
                  title={label}
                  keywords={[String(workspace.position), ...workspace.applications.map(appName)]}
                  accessories={[
                    ...icons.slice(0, maxAppIcons),
                    ...(extra > 0 ? [{ text: `+${extra}` }] : []),
                    ...(workspace.active ? [{ tag: { value: "Active", color: Color.Blue } }] : []),
                  ]}
                  detail={
                    <StripDetail
                      windows={windows ?? []}
                      workspaceID={workspace.id}
                      highlightID={focused?.id}
                      dark={dark}
                      appIcon={appIcon}
                    >
                      <List.Item.Detail.Metadata.Label
                        title="Windows"
                        text={workspace.windowCount ? String(workspace.windowCount) : "None"}
                      />
                      {displayCount > 1 ? (
                        <List.Item.Detail.Metadata.Label title="Display" text={String(display)} />
                      ) : null}
                      <List.Item.Detail.Metadata.Separator />
                    </StripDetail>
                  }
                  actions={actions(workspace, label)}
                />
              );
            })}
          </List.Section>
        );
      })}
    </List>
  );
}
