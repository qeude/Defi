import { closeMainWindow, getPreferenceValues, PopToRootType, showHUD } from "@raycast/api";
import { execFile, spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const notRunning = "Defi is not running.";
export const notInstalled = "Defi is not installed.";
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
  if (!found) throw new Error(notInstalled);
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

// Streams `defi subscribe --json`: onEvent gets each event name, onExit runs when the stream ends.
// Returns the function that stops it.
export function subscribe(onEvent: (event: string) => void, onExit: () => void): () => void {
  try {
    const child = spawn(join(defiAppPath(), cliInApp), ["subscribe", "--json"]);
    let pending = "";
    child.stdout?.on("data", (chunk: Buffer) => {
      const lines = (pending + chunk.toString()).split("\n");
      pending = lines.pop() ?? "";
      for (const line of lines) onEvent(line.match(/"event"\s*:\s*"([^"]+)"/)?.[1] ?? "");
    });
    child.on("error", () => undefined);
    child.on("close", onExit);
    return () => {
      child.removeAllListeners("close");
      child.kill();
    };
  } catch {
    onExit();
    return () => undefined;
  }
}

// Close Raycast first so the command acts on the window that was focused before it.
// Feedback is a HUD because the launcher window is already gone.
export async function runAndClose(commands: string[][], hud?: string): Promise<void> {
  await closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Immediate });
  try {
    for (const args of commands) await defi(...args);
    if (hud) await showHUD(hud);
  } catch (error) {
    await showHUD(`Defi: ${error instanceof Error ? error.message : String(error)}`);
  }
}
