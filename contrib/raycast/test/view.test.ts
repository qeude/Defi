import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { parseWindows, parseWorkspaces } from "../src/parse.ts";
import { stripColumns, stripImage } from "../src/strip.ts";
import { formatShortcut } from "../src/shortcut.ts";
import { suggestions } from "../src/suggest.ts";

const fixture = (name: string) => readFileSync(new URL(`fixtures/${name}`, import.meta.url), "utf8");
const windows = parseWindows(fixture("list-windows.json"));
const workspaces = parseWorkspaces(fixture("list-workspaces.json"));

test("strip columns follow column and row, skipping floating windows", () => {
  const stacked = [
    { id: 1, appName: "A", title: "", focused: false, workspace: { id: "w", position: 1 }, column: 2, row: 2 },
    { id: 2, appName: "B", title: "", focused: false, workspace: { id: "w", position: 1 }, column: 2, row: 1 },
    { id: 3, appName: "C", title: "", focused: false, workspace: { id: "w", position: 1 }, column: 1, row: 1 },
    { id: 4, appName: "D", title: "", focused: false, workspace: { id: "w", position: 1 } },
  ];
  assert.deepEqual(
    stripColumns(stacked, "w").map((column) => column.map((window) => window.id)),
    [[3], [2, 1]],
  );
});

test("the strip image draws one tile per tiled window and highlights one", () => {
  const image = stripImage(windows, "dev", 2613, true);
  const svg = Buffer.from(image.match(/^!\[Strip\]\(data:image\/svg\+xml;base64,([^)]+)\)$/)![1], "base64").toString();
  assert.equal(svg.match(/<rect /g)?.length, 5); // the desk and four windows
  assert.equal(svg.match(/fill="#0A84FF"/g)?.length, 1);
  assert.equal(stripImage(windows, "tools", undefined, true), "");
});

test("search text becomes a command argument", () => {
  const titles = (query: string) => suggestions(query, workspaces).map((s) => [s.title, s.args.join(" ")]);
  assert.deepEqual(titles("60"), [["Set Column Width to 60%", "set-column-width 60%"]]);
  assert.deepEqual(titles("3"), [
    ["Go to dev-secondary", "--monitor 1 workspace dev-secondary"],
    ["Move Window to dev-secondary", "move-window-to-workspace-name dev-secondary"],
    ["Send Window to dev-secondary", "send-window-to-workspace-name dev-secondary"],
    ["Move Column to dev-secondary", "move-column-to-workspace-name dev-secondary"],
    ["Send Column to dev-secondary", "send-column-to-workspace-name dev-secondary"],
  ]);
  assert.deepEqual(titles("sec").map(([title]) => title)[0], "Go to dev-secondary");
  assert.deepEqual(titles("7"), [["Set Column Width to 7%", "set-column-width 7%"]]);
  assert.deepEqual(titles("+10"), [["Widen Column by 10%", "set-column-width +10%"]]);
  assert.deepEqual(titles("-40pt"), [["Narrow Column by 40 pt", "set-column-width -40"]]);
  assert.deepEqual(titles("960"), [["Set Column Width to 960 pt", "set-column-width 960"]]);
  assert.deepEqual(titles("h50"), [["Set Window Height to 50%", "set-window-height 50%"]]);
  assert.deepEqual(titles("h-10"), [["Shrink Window by 10%", "set-window-height -10%"]]);
  assert.deepEqual(titles("We"), [
    ["Go to web", "--monitor 1 workspace web"],
    ["Move Window to web", "move-window-to-workspace-name web"],
    ["Send Window to web", "send-window-to-workspace-name web"],
    ["Move Column to web", "move-column-to-workspace-name web"],
    ["Send Column to web", "send-column-to-workspace-name web"],
  ]);
  assert.deepEqual(titles("zzz"), []);
  assert.deepEqual(titles("  "), []);
});

test("copied commands use the form [keys] accepts", () => {
  const bindings = (query: string) => suggestions(query, workspaces).map((s) => s.binding);
  assert.deepEqual(bindings("web").slice(0, 2), ["workspace web", "move-window-to-workspace-name web"]);
  assert.deepEqual(bindings("5").slice(0, 2), ["focus-workspace-position 5", "set-column-width 5%"]);
  const unnamed = { ...workspaces[4], kind: "ordinary" };
  assert.deepEqual(
    suggestions("5", [unnamed]).map((s) => s.binding),
    [
      "focus-workspace-position 5",
      "set-column-width 5%",
      "move-window-to-workspace-position 5",
      "send-window-to-workspace-position 5",
      "move-column-to-workspace-position 5",
      undefined,
    ],
  );
  assert.deepEqual(
    suggestions("2", workspaces)
      .map((s) => s.shortcut)
      .filter(Boolean),
    ["mod-2", "mod-cmd-2"],
  );
  assert.deepEqual(
    suggestions("+10", workspaces).map((s) => s.hud),
    ["Widened column by 10%"],
  );
  assert.deepEqual(
    suggestions("h-10", workspaces).map((s) => s.hud),
    ["Shrank window by 10%"],
  );
});

test("shortcuts read as macOS glyphs with the default mod", () => {
  assert.equal(formatShortcut("mod-left"), "⌃⌥←");
  assert.equal(formatShortcut("mod-shift-comma"), "⌃⌥⇧,");
  assert.equal(formatShortcut("mod-shift-cmd-up"), "⌃⌥⇧⌘↑");
  assert.equal(formatShortcut("mod-f"), "⌃⌥F");
});
