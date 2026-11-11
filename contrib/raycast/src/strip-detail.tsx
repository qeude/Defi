import { Color, Image, List } from "@raycast/api";
import type { DefiWindow } from "./parse";
import { stripColumns, stripImage } from "./strip";

type Props = {
  windows: DefiWindow[];
  workspaceID: string;
  highlightID?: number;
  dark: boolean;
  appIcon: (bundleID?: string) => Image.ImageLike | undefined;
  empty: string;
  // A picture of the highlighted window above its strip; null when macOS refused to take it.
  preview?: string | null;
  children?: React.ReactNode;
};

const maxTagLength = 24;

// The workspace's strip, then the caller's rows, then its columns named in order.
export function StripDetail({ windows, workspaceID, highlightID, dark, appIcon, empty, preview, children }: Props) {
  const columns = stripColumns(windows, workspaceID);
  const floating = windows.filter((window) => window.workspace?.id === workspaceID && window.floating);
  const onWorkspace = [...columns.flat(), ...floating];
  // When one app fills several columns, its name tells them apart no more; its titles do.
  const repeated = (window: DefiWindow) => onWorkspace.filter((other) => other.appID === window.appID).length > 1;
  const name = (window: DefiWindow) => {
    if (!repeated(window) || !window.title) return window.appName;
    return window.title.length > maxTagLength ? `${window.title.slice(0, maxTagLength - 1)}…` : window.title;
  };
  const tags = (list: DefiWindow[]) =>
    list.map((window) => (
      <List.Item.Detail.Metadata.TagList.Item
        key={window.id}
        text={name(window)}
        icon={appIcon(window.appID)}
        color={window.id === highlightID ? Color.Blue : undefined}
      />
    ));
  return (
    <List.Item.Detail
      markdown={[
        preview === null
          ? "_No picture of this window: allow Screen Recording for this launcher in System Settings, then reopen it._"
          : preview && `![Window](${preview})`,
        stripImage(windows, workspaceID, highlightID, dark) || empty,
      ]
        .filter(Boolean)
        .join("\n\n")}
      metadata={
        <List.Item.Detail.Metadata>
          {children}
          {onWorkspace.length > 0 ? <List.Item.Detail.Metadata.Separator /> : null}
          {columns.map((column, index) => (
            <List.Item.Detail.Metadata.TagList key={index} title={`Column ${index + 1}`}>
              {tags(column)}
            </List.Item.Detail.Metadata.TagList>
          ))}
          {floating.length > 0 ? (
            <List.Item.Detail.Metadata.TagList title="Floating">{tags(floating)}</List.Item.Detail.Metadata.TagList>
          ) : null}
        </List.Item.Detail.Metadata>
      }
    />
  );
}
