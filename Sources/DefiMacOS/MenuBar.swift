import AppKit
import OSLog

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
  private var workspaceNames: [String] = []
  private var activeWorkspace = ""

  public init(commandHandler: @escaping (String) -> Void) {
    self.commandHandler = commandHandler
    super.init()
    updateButton()
    rebuildMenu()
    menuBarLogger.info("Menu bar item installed")
  }

  public func update(activeWorkspace: String, workspaceNames: [String]) {
    guard self.activeWorkspace != activeWorkspace
      || self.workspaceNames != workspaceNames
    else {
      return
    }
    self.activeWorkspace = activeWorkspace
    self.workspaceNames = workspaceNames
    updateButton()
    rebuildMenu()
  }

  private func updateButton() {
    guard let button = statusItem.button else { return }
    button.image = nil
    if let index = workspaceNames.firstIndex(of: activeWorkspace) {
      button.title = String(index + 1)
      button.toolTip = "Defi — Workspace \(index + 1): \(activeWorkspace)"
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
    for workspace in workspaceNames {
      let item = commandItem(
        title: workspace == activeWorkspace ? "✓ \(workspace)" : workspace,
        command: "workspace \(workspace)"
      )
      menu.addItem(item)
    }
    if !workspaceNames.isEmpty {
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
