import { Action, ActionPanel, environment, Icon, List } from "@raycast/api";
import { useCachedState } from "@raycast/utils";
import { runAndClose } from "./defi";
import { useDesktop } from "./desktop";
import { ErrorView } from "./error-view";
import { workspaceLabel } from "./parse";
import { stripImage } from "./strip";
import { workspaceIcon } from "./workspace-icon";

const maxAppIcons = 5;

export default function Command() {
  const { windows, workspaces, isLoading, error, displayCount, appIcon } = useDesktop();
  const [showStrip, setShowStrip] = useCachedState("show-strip", false);
  const dark = environment.appearance === "dark";
  const displays = [...new Set(workspaces?.map((workspace) => workspace.display))];
  const focusedID = windows?.find((window) => window.focused)?.id;
  const appName = (bundleID: string) => windows?.find((window) => window.appID === bundleID)?.appName ?? bundleID;

  return (
    <List isLoading={isLoading} isShowingDetail={showStrip} searchBarPlaceholder="Search workspaces">
      {error && <ErrorView title="Cannot read Defi workspaces" error={error} />}
      {displays.map((display) => (
        <List.Section key={display} title={displayCount > 1 ? `Display ${display}` : undefined}>
          {workspaces
            ?.filter((workspace) => workspace.display === display)
            .map((workspace) => {
              const label = workspaceLabel(workspace);
              const icons = workspace.applications.flatMap((app) => {
                const icon = appIcon(app);
                return icon ? [{ icon, tooltip: appName(app) }] : [];
              });
              const extra = icons.length - maxAppIcons;
              return (
                <List.Item
                  key={workspace.id}
                  icon={workspaceIcon(workspace, workspace.active)}
                  title={label}
                  subtitle={workspace.windowCount === 0 ? "Empty" : undefined}
                  keywords={[String(workspace.position), ...workspace.applications]}
                  accessories={[
                    ...icons.slice(0, maxAppIcons),
                    ...(extra > 0 ? [{ text: `+${extra}` }] : []),
                    ...(workspace.active ? [{ text: "Active" }] : []),
                  ]}
                  detail={
                    <List.Item.Detail
                      markdown={stripImage(windows ?? [], workspace.id, focusedID, dark)}
                      metadata={
                        <List.Item.Detail.Metadata>
                          <List.Item.Detail.Metadata.Label title="Windows" text={String(workspace.windowCount)} />
                          {displayCount > 1 ? (
                            <List.Item.Detail.Metadata.Label title="Display" text={String(display)} />
                          ) : null}
                          {workspace.applications.length > 0 ? (
                            <List.Item.Detail.Metadata.TagList title="Apps">
                              {workspace.applications.map((app) => {
                                return (
                                  <List.Item.Detail.Metadata.TagList.Item
                                    key={app}
                                    text={appName(app)}
                                    icon={appIcon(app)}
                                  />
                                );
                              })}
                            </List.Item.Detail.Metadata.TagList>
                          ) : null}
                        </List.Item.Detail.Metadata>
                      }
                    />
                  }
                  actions={
                    <ActionPanel>
                      <Action
                        title="Show Workspace"
                        icon={Icon.Eye}
                        onAction={() => runAndClose([["--monitor", String(display), "workspace", workspace.id]])}
                      />
                      <Action
                        title="Move Focused Window Here"
                        icon={Icon.Window}
                        shortcut={{ modifiers: ["cmd"], key: "return" }}
                        onAction={() =>
                          runAndClose([["move-window-to-workspace-name", workspace.id]], `Window → ${label}`)
                        }
                      />
                      <Action
                        title="Move Focused Column Here"
                        icon={Icon.AppWindowSidebarLeft}
                        shortcut={{ modifiers: ["opt"], key: "return" }}
                        onAction={() =>
                          runAndClose([["move-column-to-workspace-name", workspace.id]], `Column → ${label}`)
                        }
                      />
                      <Action
                        title={showStrip ? "Hide Strip" : "Show Strip"}
                        icon={Icon.AppWindowSidebarRight}
                        shortcut={{ modifiers: ["cmd"], key: "d" }}
                        onAction={() => setShowStrip(!showStrip)}
                      />
                    </ActionPanel>
                  }
                />
              );
            })}
        </List.Section>
      ))}
    </List>
  );
}
