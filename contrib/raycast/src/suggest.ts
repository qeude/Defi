import { workspaceLabel, type DefiWorkspace } from "./parse.ts";

export type Suggestion = {
  title: string;
  // What runs; `binding` is the same command in the form [keys] accepts, when there is one.
  args: string[];
  binding?: string;
  kind: "width" | "height" | "workspace" | "column" | "window";
  hud?: string;
};

// Go to, then the four moves in the order Search Workspaces offers them.
function workspaceSuggestions(workspace: DefiWorkspace): Suggestion[] {
  const label = workspaceLabel(workspace);
  const named = workspace.name !== undefined;
  const target = (byName: string, byPosition?: string) =>
    named ? `${byName} ${workspace.name}` : byPosition && `${byPosition} ${workspace.position}`;
  return [
    {
      title: `Go to ${label}`,
      args: ["--monitor", String(workspace.display), "workspace", workspace.id],
      binding: target("workspace", "focus-workspace-position"),
      kind: "workspace",
    },
    {
      title: `Move Window to ${label}`,
      args: ["move-window-to-workspace-name", workspace.id],
      binding: target("move-window-to-workspace-name", "move-window-to-workspace-position"),
      kind: "window",
      hud: `Moved window to ${label}`,
    },
    {
      title: `Send Window to ${label}`,
      args: ["send-window-to-workspace-name", workspace.id],
      binding: target("send-window-to-workspace-name", "send-window-to-workspace-position"),
      kind: "window",
      hud: `Sent window to ${label}`,
    },
    {
      title: `Move Column to ${label}`,
      args: ["move-column-to-workspace-name", workspace.id],
      binding: target("move-column-to-workspace-name", "move-column-to-workspace-position"),
      kind: "column",
      hud: `Moved column to ${label}`,
    },
    {
      title: `Send Column to ${label}`,
      args: ["send-column-to-workspace-name", workspace.id],
      binding: target("send-column-to-workspace-name"),
      kind: "column",
      hud: `Sent column to ${label}`,
    },
  ];
}

function sized(kind: "width" | "height", sign: string | undefined, amount: number, points: boolean): Suggestion {
  const value = `${sign ?? ""}${amount}${points ? "" : "%"}`;
  const shown = points ? `${amount} pt` : `${amount}%`;
  const noun = kind === "width" ? "Column Width" : "Window Height";
  const title = !sign
    ? `Set ${noun} to ${shown}`
    : kind === "width"
      ? `${sign === "+" ? "Widen" : "Narrow"} Column by ${shown}`
      : `${sign === "+" ? "Grow" : "Shrink"} Window by ${shown}`;
  const command = kind === "width" ? "set-column-width" : "set-window-height";
  return { title, args: [command, value], binding: `${command} ${value}`, kind, hud: title };
}

// Commands whose argument is the search text: "60" sets a width, "h50" a stacked window's height,
// "+10" widens, "2" or "web" targets a workspace.
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
    // Defi clamps a width to at least 5% of the usable width.
    if (sign ? amount > 0 : points || amount >= 5) result.push(sized("width", sign, amount, points));
  }

  const height = text.match(/^h\s*([+-])?(\d{1,3})\s*%?$/i);
  if (height && Number(height[2]) > 0 && Number(height[2]) <= 100) {
    result.push(sized("height", height[1], Number(height[2]), false));
  }

  const lowered = text.toLowerCase();
  for (const workspace of workspaces) {
    if (workspace.name?.toLowerCase().startsWith(lowered)) result.push(...workspaceSuggestions(workspace));
  }
  return result;
}
