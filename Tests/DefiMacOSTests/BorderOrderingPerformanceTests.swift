import AppKit
import DefiModel
import DefiCore
import Testing
@testable import DefiMacOS

struct BorderOrderingPerformanceTests {
  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1"))
  func movingBorderOrdering() throws {
    var now = 0.0
    let overlay = BorderOverlay(windowID: WindowID(rawValue: 1), now: { now })
    defer { overlay.hide() }
    let started = ProcessInfo.processInfo.systemUptime
    for index in 0..<120 {
      now = Double(index) / 120
      overlay.sync(frame: Rect(x: 100 + Double(index), y: 100, width: 800, height: 600),
        width: 4, color: 0xffff_ffff, windowRadius: 12, captureEnabled: false, placement: .inside)
      overlay.applyCompositorFallback()
      overlay.revealPendingOpacity()
    }
    let panels = NSApp.windows.filter { overlay.windowIDs.contains(CGWindowID($0.windowNumber)) }
    let errors = panels.count == 4 && panels.allSatisfy({ $0.isVisible && $0.alphaValue == 1 }) ? 0 : 1
    #expect(errors == 0)
    let record: [String: Any] = ["case": "border-ordering", "operations": 120, "errors": errors,
      "output": ["visible_panels": panels.count], "metrics": ["order_calls": Double(overlay.orderingCount),
        "elapsed_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000]]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
  }
}
