import { Action, ActionPanel, environment, Icon, List } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { defi, runAndClose } from "./defi";
import { ErrorView } from "./error-view";
import { parseWindows, parseWorkspaces, workspaceLabel, type DefiWorkspace } from "./parse";
import { stripMarkdown } from "./strip";

export default function Command() {
  const { data, isLoading, error } = usePromise(async () => parseWorkspaces(await defi("list-workspaces", "--json")));
  const windows = usePromise(async () => parseWindows(await defi("list-windows", "--json")));
  const displays = [...new Set(data?.map((workspace) => workspace.display))];
  const focusedID = windows.data?.find((window) => window.focused)?.id;
  const dark = environment.appearance === "dark";

  const detail = (workspace: DefiWorkspace) =>
    [
      `## ${workspaceLabel(workspace)}`,
      stripMarkdown(windows.data ?? [], workspace.id, focusedID, dark),
      [
        displays.length > 1 && `Display ${workspace.display}`,
        workspace.windowCount === 1 ? "1 window" : `${workspace.windowCount} windows`,
      ]
        .filter(Boolean)
        .join(" · "),
    ].join("\n\n");

  return (
    <List isLoading={isLoading} isShowingDetail={Boolean(data?.length)} searchBarPlaceholder="Search workspaces">
      {error && <ErrorView title="Cannot read Defi workspaces" error={error} />}
      {displays.map((display) => (
        <List.Section key={display} title={displays.length > 1 ? `Display ${display}` : undefined}>
          {data
            ?.filter((workspace) => workspace.display === display)
            .map((workspace) => {
              const label = workspaceLabel(workspace);
              return (
                <List.Item
                  key={workspace.id}
                  icon={workspace.active ? Icon.CheckCircle : Icon.Circle}
                  title={label}
                  keywords={[String(workspace.position)]}
                  accessories={workspace.kind === "trailing" ? [{ tag: "Empty" }] : []}
                  detail={<List.Item.Detail markdown={detail(workspace)} />}
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
                        onAction={() =>
                          runAndClose([["move-window-to-workspace-name", workspace.id]], `Window → ${label}`)
                        }
                      />
                      <Action
                        title="Move Focused Column Here"
                        icon={Icon.AppWindowSidebarLeft}
                        onAction={() =>
                          runAndClose([["move-column-to-workspace-name", workspace.id]], `Column → ${label}`)
                        }
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
