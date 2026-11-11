import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { defi, runAndClose } from "./defi";
import { parseWorkspaces, workspaceLabel } from "./parse";

export default function Command() {
  const { data, isLoading, error } = usePromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")));
  const displays = [...new Set(data?.map((workspace) => workspace.display))];

  return (
    <List isLoading={isLoading} searchBarPlaceholder="Search workspaces">
      {error && <List.EmptyView icon={Icon.Warning} title="Cannot read Defi workspaces" description={error.message} />}
      {displays.map((display) => (
        <List.Section key={display} title={displays.length > 1 ? `Display ${display}` : undefined}>
          {data
            ?.filter((workspace) => workspace.display === display)
            .map((workspace) => (
              <List.Item
                key={workspace.id}
                icon={workspace.active ? Icon.CheckCircle : Icon.Circle}
                title={workspaceLabel(workspace)}
                subtitle={workspace.kind === "trailing" ? "Empty" : undefined}
                keywords={[String(workspace.position)]}
                accessories={[
                  {
                    text: workspace.windowCount === 1 ? "1 window" : `${workspace.windowCount} windows`,
                  },
                ]}
                actions={
                  <ActionPanel>
                    <Action
                      title="Show Workspace"
                      icon={Icon.Eye}
                      onAction={() => runAndClose(["--monitor", String(display), "workspace", workspace.id])}
                    />
                    <Action
                      title="Move Focused Window Here"
                      icon={Icon.Window}
                      onAction={() => runAndClose(["move-window-to-workspace-name", workspace.id])}
                    />
                    <Action
                      title="Move Focused Column Here"
                      icon={Icon.AppWindowSidebarLeft}
                      onAction={() => runAndClose(["move-column-to-workspace-name", workspace.id])}
                    />
                  </ActionPanel>
                }
              />
            ))}
        </List.Section>
      ))}
    </List>
  );
}
