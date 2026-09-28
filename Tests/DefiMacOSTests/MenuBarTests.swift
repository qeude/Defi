import Testing
import AppKit

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
  func workspaceIconsFollowSelectionAndUnavailableSymbolsFallBack() {
    let state = MenuBarState(accessibilityTrusted: { true })
    let rows = [MenuWorkspace(id: "dev", label: "dev", icon: "terminal"),
      MenuWorkspace(id: "web", label: "web", icon: "not.a.real.defi.symbol"),
      MenuWorkspace(id: "ordinary", label: "3")]
    state.update(activeWorkspace: "dev", workspaces: rows, workspaceStyle: .iconAndName)
    #expect(state.activeIcon == "terminal")
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
