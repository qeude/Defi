import { Action, ActionPanel, Icon, Keyboard, List, openExtensionPreferences } from "@raycast/api";
import { defiAppPath, notRunning } from "./defi";

function launchTarget(): string | undefined {
  try {
    return defiAppPath();
  } catch {
    return undefined;
  }
}

// Recovery for every read failure: launch Defi, try again, or fix the app in the preferences.
export function RecoveryActions({ error, onRetry }: { error: Error; onRetry: () => void }) {
  const app = error.message === notRunning ? launchTarget() : undefined;
  return (
    <ActionPanel>
      {app ? (
        <Action.Open title="Launch Defi" icon={Icon.Power} target={app} onOpen={() => setTimeout(onRetry, 1500)} />
      ) : null}
      <Action
        title="Try Again"
        icon={Icon.ArrowClockwise}
        shortcut={Keyboard.Shortcut.Common.Refresh}
        onAction={onRetry}
      />
      <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
    </ActionPanel>
  );
}

export function ErrorView({ error, onRetry }: { error: Error; onRetry: () => void }) {
  const stopped = error.message === notRunning;
  return (
    <List.EmptyView
      icon={stopped ? Icon.Power : Icon.Warning}
      title={stopped ? "Defi Is Not Running" : "Cannot Reach Defi"}
      description={stopped ? "Press Enter to launch it." : error.message}
      actions={<RecoveryActions error={error} onRetry={onRetry} />}
    />
  );
}
