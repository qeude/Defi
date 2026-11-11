import { closeMainWindow, getPreferenceValues, showHUD } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";
import { execFile } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const notRunning = "Defi is not running.";
const cliInApp = "Contents/MacOS/defi";

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Raycast stores a picked app as an object, Tinycast as its path.
function pickedApp(): string | undefined {
  const picked = getPreferenceValues<Preferences>().defiApp as unknown;
  const path = typeof picked === "string" ? picked : (picked as { path?: string } | undefined)?.path;
  return path?.trim() || undefined;
}

export function defiAppPath(): string {
  const picked = pickedApp();
  if (picked) {
    if (isExecutable(join(picked, cliInApp))) return picked;
    throw new Error(`${picked} has no defi command line tool. Pick Defi.app in the extension preferences.`);
  }
  const found = ["/Applications/Defi.app", join(homedir(), "Applications/Defi.app")].find((app) =>
    isExecutable(join(app, cliInApp)),
  );
  if (!found)
    throw new Error("Defi is not installed in Applications. Install it, or pick Defi.app in the preferences.");
  return found;
}

export function defi(...args: string[]): Promise<string> {
  const cli = join(defiAppPath(), cliInApp);
  return new Promise((resolve, reject) => {
    execFile(cli, args, { timeout: 5000 }, (error, stdout, stderr) => {
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
    await showFailureToast(error, { title: "Defi could not do that" });
  }
}
