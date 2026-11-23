import AppKit
import DefiModel
import Testing

@testable import DefiMacOS

struct RibbonProxyRecordingTests {
  @Test @MainActor
  func overlayIsSharedWithScreenRecordings() {
    let panel = RibbonProxyRenderer.overlayPanel(
      frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    // Recordings and screen sharing show the motion the user sees.
    #expect(panel.sharingType == .readOnly)
    // Above ordinary windows, and never over a full-screen Space.
    #expect(panel.level.rawValue == NSWindow.Level.normal.rawValue + 2)
    #expect(
      panel.collectionBehavior == [.canJoinAllSpaces, .stationary, .ignoresCycle])
  }
}
