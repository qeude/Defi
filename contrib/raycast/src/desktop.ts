import { getApplications } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { defi } from "./defi";
import { parseWindows, parseWorkspaces } from "./parse";

async function readDesktop() {
  const [windows, workspaces] = await Promise.all([
    defi("list-windows", "--json").then(parseWindows),
    defi("list-workspaces", "--json").then(parseWorkspaces),
  ]);
  return { windows, workspaces };
}

// Windows and workspaces read together, shown from the last run while they reload.
export function useDesktop() {
  // The empty view reports the error with its recovery actions, so no toast as well.
  const desktop = useCachedPromise(readDesktop, [], { onError: () => undefined });
  const apps = useCachedPromise(async () =>
    (await getApplications()).map(({ bundleId, name, path }) => ({ bundleId, name, path })),
  );
  const appsByID = new Map(apps.data?.map((app) => [app.bundleId, app]));
  const windows = desktop.data?.windows;
  return {
    windows,
    workspaces: desktop.data?.workspaces,
    isLoading: desktop.isLoading,
    error: desktop.error,
    revalidate: desktop.revalidate,
    displayCount: new Set(desktop.data?.workspaces.map((workspace) => workspace.display)).size,
    focused: windows?.find((window) => window.focused),
    appIcon: (bundleID?: string) => {
      const path = bundleID ? appsByID.get(bundleID)?.path : undefined;
      return path ? { fileIcon: path } : undefined;
    },
    appName: (bundleID: string) =>
      appsByID.get(bundleID)?.name ?? windows?.find((window) => window.appID === bundleID)?.appName ?? bundleID,
  };
}
