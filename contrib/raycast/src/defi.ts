import { closeMainWindow, getPreferenceValues, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const bundledCLI = "Defi.app/Contents/MacOS/defi";
export const notRunning = "Defi is not running.";

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function defiPath(): string {
  const custom = getPreferenceValues<Preferences>().defiPath?.trim();
  if (custom) {
    if (isExecutable(custom)) return custom;
    throw new Error(`No executable defi at ${custom}. Fix the path in the extension preferences.`);
  }
  const found = [join("/Applications", bundledCLI), join(homedir(), "Applications", bundledCLI)].find(isExecutable);
  if (!found)
    throw new Error("Defi.app was not found in /Applications or ~/Applications. Set its path in the preferences.");
  return found;
}

// The app bundle around the CLI, when the CLI sits in one.
export function defiAppPath(): string | undefined {
  try {
    const app = dirname(dirname(dirname(defiPath())));
    return app.endsWith(".app") ? app : undefined;
  } catch {
    return undefined;
  }
}

export function defi(...args: string[]): Promise<string> {
  const path = defiPath();
  return new Promise((resolve, reject) => {
    execFile(path, args, { timeout: 5000 }, (error, stdout, stderr) => {
      if (!error) return resolve(stdout);
      const message = stderr.trim() || error.message;
      reject(new Error(message.includes("connect failed") ? notRunning : message));
    });
  });
}

// Close Raycast first so the command acts on the window that was focused before it.
export async function runAndClose(commands: string[][], hud?: string): Promise<void> {
  await closeMainWindow({ clearRootSearch: true });
  try {
    for (const args of commands) await defi(...args);
    if (hud) await showHUD(hud);
  } catch (error) {
    await showFailureToast(error, { title: "Defi command failed" });
  }
}
