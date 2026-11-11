import { defi } from "./defi";

export type Preview = { picture: string } | { problem: string };

// Defi's own latest picture of the window: the launcher captures nothing and needs no permission.
export async function windowPreview(windowID: number): Promise<Preview> {
  try {
    return { picture: (await defi("window-preview", String(windowID))).trim() };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    // Defi words its own refusals; anything else is a Defi older than window-preview.
    return { problem: message.startsWith("Defi") ? message : "Update Defi to see window pictures." };
  }
}
