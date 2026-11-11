import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { defiAppPath, notRunning } from "./defi";

export function ErrorView({ title, error }: { title: string; error: Error }) {
  const app = error.message === notRunning ? defiAppPath() : undefined;
  return (
    <List.EmptyView
      icon={Icon.Warning}
      title={title}
      description={error.message}
      actions={app && <ActionPanel>{<Action.Open title="Launch Defi" target={app} />}</ActionPanel>}
    />
  );
}
