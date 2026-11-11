import type { DefiWindow } from "./parse";

const columnWidth = 36;
const height = 56;
const gap = 6;
const palette = {
  light: { window: "#D8D8DD", stroke: "#AEAEB2", highlight: "#007AFF" },
  dark: { window: "#3A3A3C", stroke: "#636366", highlight: "#0A84FF" },
};

export const escapeMarkdown = (text: string) => text.replace(/([\\`*_[\]<>#|])/g, "\\$1");

// Tiled windows of one workspace, as columns of stacked windows in strip order.
export function stripColumns(windows: DefiWindow[], workspaceID: string): DefiWindow[][] {
  const columns: DefiWindow[][] = [];
  for (const window of windows) {
    if (window.workspace?.id !== workspaceID || !window.column) continue;
    (columns[window.column - 1] ??= []).push(window);
  }
  return Array.from(columns, (column) => (column ?? []).sort((a, b) => (a.row ?? 0) - (b.row ?? 0)));
}

export function stripSVG(columns: DefiWindow[][], highlightID: number | undefined, dark: boolean): string {
  const colors = dark ? palette.dark : palette.light;
  const rects = columns.flatMap((column, index) => {
    const rowHeight = (height - gap * (column.length - 1)) / Math.max(column.length, 1);
    return column.map((window, row) => {
      const fill = window.id === highlightID ? colors.highlight : colors.window;
      const x = 1 + index * (columnWidth + gap);
      const y = 1 + row * (rowHeight + gap);
      return `<rect x="${x}" y="${y}" width="${columnWidth}" height="${rowHeight}" rx="5" fill="${fill}" stroke="${colors.stroke}"/>`;
    });
  });
  const width = Math.max(columns.length, 1) * (columnWidth + gap) - gap + 2;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height + 2}" viewBox="0 0 ${width} ${height + 2}">${rects.join("")}</svg>`;
}

// Markdown for the detail pane: the strip, then one line naming each column.
export function stripMarkdown(
  windows: DefiWindow[],
  workspaceID: string,
  highlightID: number | undefined,
  dark: boolean,
): string {
  const columns = stripColumns(windows, workspaceID);
  const floating = windows.filter((window) => window.workspace?.id === workspaceID && !window.column);
  if (columns.length === 0 && floating.length === 0) return "_No windows._";
  const lines: string[] = [];
  if (columns.length > 0) {
    const svg = Buffer.from(stripSVG(columns, highlightID, dark)).toString("base64");
    lines.push(`![Strip](data:image/svg+xml;base64,${svg})`);
    const names = columns.map((column, index) => {
      const label = `${index + 1} ${column.map((window) => escapeMarkdown(window.appName)).join(" + ")}`;
      return column.some((window) => window.id === highlightID) ? `**${label}**` : label;
    });
    lines.push(names.join(" · "));
  }
  if (floating.length > 0) {
    lines.push(`Floating: ${floating.map((window) => escapeMarkdown(window.appName)).join(", ")}`);
  }
  return lines.join("\n\n");
}
