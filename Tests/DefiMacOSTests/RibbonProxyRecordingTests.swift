import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

@MainActor
struct RibbonProxyRecordingTests {
  @Test func overlayIsSharedWithScreenRecordings() throws {
    let renderer = RibbonProxyRenderer.shared
    defer { renderer.enabled = false }
    renderer.enabled = true
    _ = try #require(renderer.prepareSurface(
      area: Rect(x: 0, y: 0, width: 200, height: 200), display: CGMainDisplayID()))
    let sharing = renderer.surfaceWindowIDs.compactMap {
      NSApplication.shared.window(withWindowNumber: Int($0))?.sharingType
    }
    #expect(sharing == [.readOnly])
  }
}
