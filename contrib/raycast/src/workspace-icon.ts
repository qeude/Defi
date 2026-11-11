import { Color, Icon, type Image } from "@raycast/api";

// The workspace's position as a numbered icon, tinted when it is the active one.
export function workspaceIcon(workspace: { position: number }, active = false): Image.ImageLike {
  const name = `Number${String(workspace.position).padStart(2, "0")}` as keyof typeof Icon;
  const source = Icon[name] ?? Icon.AppWindowGrid3x3;
  return active ? { source, tintColor: Color.Blue } : source;
}
