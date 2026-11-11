import { getApplications } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect, useRef } from "react";
import { defi, subscribe } from "./defi";
import { parseWindows, parseWorkspaces } from "./parse";

async function readDesktop() {
  const [windows, workspaces] = await Promise.all([
    defi("list-windows", "--json").then(parseWindows),
    defi("list-workspaces", "--json").then(parseWorkspaces),
  ]);
  return { windows, workspaces };
}

async function readApps() {
  return (await getApplications()).map(({ bundleId, name, path }) => ({ bundleId, name, path }));
}

// Windows and workspaces, shown from the last run at once and kept live while the view is open.
export function useDesktop() {
  // The empty view reports the error with its recovery actions, so no toast as well.
  const desktop = useCachedPromise(readDesktop, [], { onError: () => undefined });
  const apps = useCachedPromise(readApps);
  const reload = useRef(desktop.revalidate);
  reload.current = desktop.revalidate;

  useEffect(() => {
    let stopped = false;
    let reloadTimer: ReturnType<typeof setTimeout> | undefined;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let stop = () => undefined as void;
    let connections = 0;
    const start = () => {
      connections += 1;
      const reconnect = connections > 1;
      stop = subscribe(
        (event) => {
          // The first snapshot repeats what was just read; after a reconnect it is news.
          if (event === "snapshot" && !reconnect) return;
          // Defi batches changes within about 30 ms; reload once per burst.
          clearTimeout(reloadTimer);
          reloadTimer = setTimeout(() => reload.current(), 60);
        },
        // Defi stopped or is not running yet: keep trying while the view is open.
        () => {
          if (!stopped) retryTimer = setTimeout(start, 2000);
        },
      );
    };
    start();
    return () => {
      stopped = true;
      clearTimeout(reloadTimer);
      clearTimeout(retryTimer);
      stop();
    };
  }, []);

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
    // The workspace the user is on, even when it holds no window.
    current: desktop.data?.workspaces.find((workspace) => workspace.active && workspace.focusedDisplay),
    appIcon: (bundleID?: string) => {
      const path = bundleID ? appsByID.get(bundleID)?.path : undefined;
      return path ? { fileIcon: path } : undefined;
    },
    appName: (bundleID: string) =>
      appsByID.get(bundleID)?.name ?? windows?.find((window) => window.appID === bundleID)?.appName ?? bundleID,
  };
}
