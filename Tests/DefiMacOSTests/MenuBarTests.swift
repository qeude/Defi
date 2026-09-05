import Testing

@testable import DefiMacOS

@MainActor
struct MenuBarTests {
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
