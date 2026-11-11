import { execFile } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const maxSide = "800";

function run(file: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) =>
    execFile(file, args, { timeout: 3000 }, (error) => (error ? reject(error) : resolve())),
  );
}

// A picture of one window as a data URI, or undefined when macOS refuses (no Screen Recording).
// The file only lives while it is read: these are pictures of the user's windows.
export async function capturePreview(windowID: number): Promise<string | undefined> {
  const folder = mkdtempSync(join(tmpdir(), "defi-preview-"));
  const file = join(folder, "window.jpg");
  try {
    await run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(windowID), "-t", "jpg", file]);
    await run("/usr/bin/sips", ["-Z", maxSide, "-s", "formatOptions", "70", file]);
    return `data:image/jpeg;base64,${readFileSync(file).toString("base64")}`;
  } catch {
    return undefined;
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
}
