import ApplicationServices
import Observation
import DefiConfig
import AppKit

public struct MenuWorkspace: Equatable, Sendable {
  public let id: String
  public let label: String
  public let icon: String?

  public init(id: String, label: String, icon: String? = nil) {
    self.id = id
    self.label = label
    self.icon = icon
  }
}

@MainActor
@Observable
public final class MenuBarState {
  public private(set) var activeIconImage: NSImage?
  public var isInserted = true
  public private(set) var workspaceStyle: WorkspaceLabelStyle = .name
  public private(set) var workspaces: [MenuWorkspace] = []
  public private(set) var activeWorkspace = ""
  public private(set) var needsAccessibilityPermission: Bool
  private let accessibilityTrusted: () -> Bool

  public init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.accessibilityTrusted = accessibilityTrusted
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  public func refreshAccessibilityPermission() {
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  public var activeLabel: String {
    workspaces.first { $0.id == activeWorkspace }?.label ?? "–"
  }

  public private(set) var activeIcon: String?
  private var requestedIcon: String?

  public func update(activeWorkspace: String, workspaces: [MenuWorkspace], workspaceStyle: WorkspaceLabelStyle = .name) {
    let icon = workspaces.first(where: { $0.id == activeWorkspace })?.icon
    if self.workspaceStyle != workspaceStyle { self.workspaceStyle = workspaceStyle }
    if self.activeWorkspace != activeWorkspace { self.activeWorkspace = activeWorkspace }
    if self.workspaces != workspaces { self.workspaces = workspaces }
    if requestedIcon != icon {
      requestedIcon = icon
      let image = icon.flatMap(menuBarWorkspaceImage)
      activeIcon = icon.map { image == nil ? "square.grid.2x2" : $0 }
      activeIconImage = image ?? activeIcon.flatMap(menuBarWorkspaceImage)
    }
  }
}

/// A fixed canvas keeps the native status item width independent of symbol proportions.
@MainActor
func menuBarWorkspaceImage(_ symbol: String) -> NSImage? {
  guard let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)) else { return nil }
  let scale = min(16 / source.size.width, 16 / source.size.height)
  let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
  let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
    source.draw(in: NSRect(x: (bounds.width - size.width) / 2,
      y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    return true
  }
  image.isTemplate = true
  return image
}
