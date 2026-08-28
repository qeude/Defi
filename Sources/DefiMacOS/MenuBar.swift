import AppKit
import OSLog

public struct MenuWorkspace: Equatable, Sendable {
  public let id: String
  public let label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

private let menuBarLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "MenuBar"
)

@MainActor
public final class MenuBarController: NSObject {
  private let statusItem = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.variableLength
  )
  private let commandHandler: (String) -> Void
  private var workspaces: [MenuWorkspace] = []
  private var activeWorkspace = ""

  public init(commandHandler: @escaping (String) -> Void) {
    self.commandHandler = commandHandler
    super.init()
    updateButton()
    rebuildMenu()
    menuBarLogger.info("Menu bar item installed")
  }

  public func update(activeWorkspace: String, workspaces: [MenuWorkspace]) {
    guard
      self.activeWorkspace != activeWorkspace
        || self.workspaces != workspaces
    else {
      return
    }
    self.activeWorkspace = activeWorkspace
    self.workspaces = workspaces
    updateButton()
    rebuildMenu()
  }

  private func updateButton() {
    guard let button = statusItem.button else { return }
    button.image = nil
    if let workspace = workspaces.first(where: { $0.id == activeWorkspace }) {
      button.title = workspace.label
      button.toolTip = "Defi — Workspace \(workspace.label)"
    } else {
      button.title = "–"
      button.toolTip = "Defi"
    }
    button.font = .monospacedDigitSystemFont(
      ofSize: NSFont.systemFontSize,
      weight: .semibold
    )
    button.setAccessibilityLabel("Defi workspace")
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    for workspace in workspaces {
      let item = commandItem(
        title: workspace.id == activeWorkspace ? "✓ \(workspace.label)" : workspace.label,
        command: "workspace \(workspace.id)"
      )
      menu.addItem(item)
    }
    if !workspaces.isEmpty {
      menu.addItem(.separator())
    }
    menu.addItem(commandItem(title: "Quit Defi", command: "quit"))
    statusItem.menu = menu
  }

  private func commandItem(title: String, command: String) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: #selector(runCommand(_:)),
      keyEquivalent: ""
    )
    item.target = self
    item.representedObject = command
    return item
  }

  @objc
  private func runCommand(_ sender: NSMenuItem) {
    guard let command = sender.representedObject as? String else { return }
    menuBarLogger.info("Menu command: \(command, privacy: .public)")
    commandHandler(command)
  }
}
