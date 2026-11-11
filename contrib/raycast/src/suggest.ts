import type { DefiWorkspace } from "./parse";

export type Suggestion = { title: string; args: string[]; hud?: string };

// Commands whose argument is the search text: "60" sets a width, "+10" widens, "web" targets a workspace.
export function suggestions(query: string, workspaces: DefiWorkspace[]): Suggestion[] {
  const text = query.trim();
  if (!text) return [];
  const result: Suggestion[] = [];

  const width = text.match(/^([+-])?(\d{1,4})\s*(%|pt|px)?$/i);
  if (width) {
    const [, sign, digits, unit] = width;
    const amount = Number(digits);
    if (!sign && !unit && amount >= 1 && amount <= 9) {
      result.push({ title: `Go to Workspace ${amount}`, args: ["focus-workspace-position", digits] });
    }
    const points = unit ? unit !== "%" : amount > 100;
    const shown = points ? `${amount} pt` : `${amount}%`;
    // Defi clamps a width to at least 5% of the usable width.
    if (sign ? amount > 0 : points || amount >= 5) {
      const value = `${sign ?? ""}${amount}${points ? "" : "%"}`;
      const title = !sign ? `Set Column Width to ${shown}` : `${sign === "+" ? "Widen" : "Narrow"} Column by ${shown}`;
      result.push({ title, args: ["set-column-width", value], hud: title });
    }
  }

  const lowered = text.toLowerCase();
  for (const workspace of workspaces) {
    const label = workspace.name;
    if (!label?.toLowerCase().startsWith(lowered)) continue;
    result.push(
      { title: `Go to ${label}`, args: ["--monitor", String(workspace.display), "workspace", workspace.id] },
      {
        title: `Move Column to ${label}`,
        args: ["move-column-to-workspace-name", workspace.id],
        hud: `Column → ${label}`,
      },
      {
        title: `Move Window to ${label}`,
        args: ["move-window-to-workspace-name", workspace.id],
        hud: `Window → ${label}`,
      },
    );
  }
  return result;
}
