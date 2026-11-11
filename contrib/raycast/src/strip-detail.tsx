import { Color, Image, List } from "@raycast/api";
import type { DefiWindow } from "./parse";
import { stripColumns, stripImage } from "./strip";

type Props = {
  windows: DefiWindow[];
  workspaceID: string;
  highlightID?: number;
  dark: boolean;
  appIcon: (bundleID?: string) => Image.ImageLike | undefined;
  children?: React.ReactNode;
};

// The workspace's strip with its columns named in order, under the rows the caller adds first.
export function StripDetail({ windows, workspaceID, highlightID, dark, appIcon, children }: Props) {
  const columns = stripColumns(windows, workspaceID);
  const floating = windows.filter((window) => window.workspace?.id === workspaceID && window.floating);
  const tags = (list: DefiWindow[]) =>
    list.map((window) => (
      <List.Item.Detail.Metadata.TagList.Item
        key={window.id}
        text={window.appName}
        icon={appIcon(window.appID)}
        color={window.id === highlightID ? Color.Blue : undefined}
      />
    ));
  return (
    <List.Item.Detail
      markdown={stripImage(windows, workspaceID, highlightID, dark)}
      metadata={
        <List.Item.Detail.Metadata>
          {children}
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
