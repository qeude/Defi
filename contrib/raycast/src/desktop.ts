import { getApplications } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import { defi } from "./defi";
import { parseWindows, parseWorkspaces } from "./parse";

// Windows, workspaces, and app paths, read together so a view renders once with all of them.
export function useDesktop() {
  const { data, isLoading, error } = usePromise(async () => {
    const [windows, workspaces, apps] = await Promise.all([
      defi("list-windows", "--json").then(parseWindows),
      defi("list-workspaces", "--json").then(parseWorkspaces),
      getApplications().catch(() => []),
    ]);
    return { windows, workspaces, appPaths: new Map(apps.map((app) => [app.bundleId, app.path])) };
  });
  const displayCount = new Set(data?.workspaces.map((workspace) => workspace.display)).size;
  const appIcon = (bundleID?: string) => {
    const path = bundleID ? data?.appPaths.get(bundleID) : undefined;
    return path ? { fileIcon: path } : undefined;
  };
  return { ...data, isLoading, error, displayCount, appIcon };
}
