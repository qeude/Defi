import { Action, ActionPanel, Icon, Keyboard, List, openExtensionPreferences } from "@raycast/api";
import { defiAppPath, notInstalled, notRunning } from "./defi";
import { VersionMismatch } from "./parse";

const releases = "https://github.com/qeude/Defi/releases/latest";

export function describeError(error: Error) {
  if (error.message === notRunning) {
    return { icon: Icon.Power, title: "Defi Is Not Running", description: "Press Enter to launch it." };
  }
  if (error.message === notInstalled) {
    return {
      icon: Icon.Download,
      title: "Defi Is Not Installed",
      description: "Download Defi, or pick Defi.app in the extension preferences.",
    };
  }
  if (error instanceof VersionMismatch) {
    return {
      icon: Icon.ArrowClockwise,
      title: error.received > error.supported ? "Update This Extension" : "Update Defi",
      description:
        error.received > error.supported
          ? "Defi is newer than this extension. Rebuild the extension from the Defi repository."
          : "This extension needs a newer Defi. Update Defi from its menu bar item or the releases page.",
    };
  }
  return { icon: Icon.Warning, title: "Cannot Reach Defi", description: error.message };
}

// Recovery for every read failure: install or launch Defi, try again, or pick the app in the preferences.
export function RecoveryActions({ error, onRetry }: { error: Error; onRetry: () => void }) {
  const preferences = (
    <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openExtensionPreferences} />
  );
  if (error.message === notInstalled) {
    return (
      <ActionPanel>
        <Action.OpenInBrowser title="Download Defi" url={releases} />
        {preferences}
      </ActionPanel>
    );
  }
  return (
    <ActionPanel>
      {error.message === notRunning ? (
        <Action.Open
          title="Launch Defi"
          icon={Icon.Power}
          target={defiAppPath()}
          onOpen={() => setTimeout(onRetry, 1500)}
        />
      ) : null}
      <Action
        title="Try Again"
        icon={Icon.ArrowClockwise}
        shortcut={Keyboard.Shortcut.Common.Refresh}
        onAction={onRetry}
      />
      {preferences}
    </ActionPanel>
  );
}

export function ErrorView({ error, onRetry }: { error: Error; onRetry: () => void }) {
  return <List.EmptyView {...describeError(error)} actions={<RecoveryActions error={error} onRetry={onRetry} />} />;
}
