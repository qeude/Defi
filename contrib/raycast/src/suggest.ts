import { workspaceLabel, type DefiWorkspace } from "./parse.ts";

export type Suggestion = {
  title: string;
  args: string[];
  kind: "width" | "workspace" | "column" | "window";
  hud?: string;
};

function workspaceSuggestions(workspace: DefiWorkspace): Suggestion[] {
  const label = workspaceLabel(workspace);
  return [
    {
      title: `Go to ${label}`,
      args: ["--monitor", String(workspace.display), "workspace", workspace.id],
      kind: "workspace",
    },
    {
      title: `Move Column to ${label}`,
      args: ["move-column-to-workspace-name", workspace.id],
      kind: "column",
      hud: `Moved column to ${label}`,
    },
    {
      title: `Move Window to ${label}`,
      args: ["move-window-to-workspace-name", workspace.id],
      kind: "window",
      hud: `Moved window to ${label}`,
    },
    {
      title: `Send Window to ${label}`,
      args: ["send-window-to-workspace-name", workspace.id],
      kind: "window",
      hud: `Sent window to ${label}`,
    },
  ];
}

// Commands whose argument is the search text: "60" sets a width, "+10" widens, "web" or "2" targets a workspace.
export function suggestions(query: string, workspaces: DefiWorkspace[]): Suggestion[] {
  const text = query.trim();
  if (!text) return [];
  const result: Suggestion[] = [];

  const width = text.match(/^([+-])?(\d{1,4})\s*(%|pt|px)?$/i);
  if (width) {
    const [, sign, digits, unit] = width;
    const amount = Number(digits);
    const byPosition = !sign && !unit && workspaces.find((w) => w.focusedDisplay && w.position === amount);
    if (byPosition) result.push(workspaceSuggestions(byPosition)[0]);
    const points = unit ? unit !== "%" : amount > 100;
    const shown = points ? `${amount} pt` : `${amount}%`;
    // Defi clamps a width to at least 5% of the usable width.
    if (sign ? amount > 0 : points || amount >= 5) {
      const value = `${sign ?? ""}${amount}${points ? "" : "%"}`;
      const title = !sign ? `Set Column Width to ${shown}` : `${sign === "+" ? "Widen" : "Narrow"} Column by ${shown}`;
      result.push({ title, args: ["set-column-width", value], kind: "width", hud: title });
    }
  }

  const lowered = text.toLowerCase();
  for (const workspace of workspaces) {
    if (workspace.name?.toLowerCase().startsWith(lowered)) result.push(...workspaceSuggestions(workspace));
  }
  return result;
}
