import Testing
import AppKit
import class SwiftUI.NSHostingMenu

@testable import DefiMacOS

@MainActor
struct MenuBarTests {
  @Test
  func workspaceSymbolsHaveIdenticalMenuBarCanvasSizes() throws {
    for symbol in ["globe", "hammer", "terminal", "arrow.left.and.right"] {
      let image = try #require(menuBarWorkspaceImage(symbol))
      #expect(image.size == NSSize(width: 18, height: 18))
      #expect(image.isTemplate)
      #expect(image.tiffRepresentation != nil)
    }
  }

  @Test
  func swiftUIMenuKeepsWorkspaceSelectionAndCommandRouting() throws {
    var commands: [String] = []
    let state = MenuBarState(accessibilityTrusted: { true })
    state.update(
      activeWorkspace: "dev",
      workspaces: [MenuWorkspace(id: "dev", label: "Dev"), MenuWorkspace(id: "web", label: "Web")]
    )
    let menu = NSHostingMenu(rootView: MenuBarContent(state: state, commandHandler: { commands.append($0) }))
    menu.update()
    #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Workspaces", "Settings…", "Quit Defi"])
    let settings = try #require(menu.items.first { $0.title == "Settings…" })
    #expect(settings.image == nil)
    #expect(settings.keyEquivalent == ",")
    #expect(settings.keyEquivalentModifierMask == .command)
    let workspaces = try #require(menu.items.first { $0.title == "Workspaces" }?.submenu)
    workspaces.update()
    #expect(workspaces.items.first { $0.title == "Dev" }?.state == .on)
    workspaces.performActionForItem(at: try #require(workspaces.items.firstIndex { $0.title == "Web" }))
    menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Quit Defi" }))
    let deadline = Date().addingTimeInterval(1)
    while commands.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    #expect(commands == ["workspace web", "quit"])
  }

  @Test
  func workspaceIconsFollowSelectionAndUnavailableSymbolsFallBack() {
    let state = MenuBarState(accessibilityTrusted: { true })
    let rows = [MenuWorkspace(id: "dev", label: "dev", icon: "terminal"),
      MenuWorkspace(id: "web", label: "web", icon: "not.a.real.defi.symbol"),
      MenuWorkspace(id: "ordinary", label: "3")]
    state.update(activeWorkspace: "dev", workspaces: rows, workspaceStyle: .iconAndName)
    #expect(state.activeIcon == "terminal")
    let image = state.activeIconImage
    state.update(activeWorkspace: "dev", workspaces: rows, workspaceStyle: .iconAndName)
    #expect(state.activeIconImage === image)
    #expect(state.workspaceStyle == .iconAndName)
    state.update(activeWorkspace: "web", workspaces: rows, workspaceStyle: .icon)
    #expect(state.activeIcon == "square.grid.2x2")
    state.update(activeWorkspace: "ordinary", workspaces: rows, workspaceStyle: .icon)
    #expect(state.activeIcon == nil)
    #expect(state.activeLabel == "3")
  }

  @Test
  func refreshesAccessibilityPermissionWhenMenuOpens() {
    var trusted = false
    let state = MenuBarState(accessibilityTrusted: { trusted })
    #expect(state.needsAccessibilityPermission)

    trusted = true
    state.refreshAccessibilityPermission()
    #expect(!state.needsAccessibilityPermission)

    trusted = false
    state.refreshAccessibilityPermission()
    #expect(state.needsAccessibilityPermission)
  }

  @Test
  func keepsActiveWorkspaceLabel() {
    let state = MenuBarState(accessibilityTrusted: { true })
    state.update(activeWorkspace: "dev", workspaces: [
      MenuWorkspace(id: "dev", label: "Development"),
      MenuWorkspace(id: "__dynamic", label: "+"),
    ])
    #expect(state.activeLabel == "Development")
    #expect(!state.needsAccessibilityPermission)
  }
}
