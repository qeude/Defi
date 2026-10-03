import AppKit
import Darwin
import Foundation

private typealias MainConnectionID = @convention(c) () -> Int32
private typealias MoveWindow = @convention(c) (Int32, UInt32, UnsafePointer<CGPoint>) -> Int32
private typealias GetWindowBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

@main
private struct PrivateFrameProbe {
  @MainActor
  static func main() {
    do {
      try run()
    } catch {
      fputs("private-frame-probe: \(error.localizedDescription)\n", stderr)
      exit(EXIT_FAILURE)
    }
  }

  @MainActor
  private static func run() throws {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let library = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
      throw failure("SkyLight could not be loaded")
    }
    defer { dlclose(library) }
    guard let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
      let moveSymbol = dlsym(library, "SLSMoveWindow"),
      let boundsSymbol = dlsym(library, "SLSGetWindowBounds")
    else {
      throw failure("Required SkyLight symbols are unavailable")
    }
    let connection = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)()
    let move = unsafeBitCast(moveSymbol, to: MoveWindow.self)
    let getBounds = unsafeBitCast(boundsSymbol, to: GetWindowBounds.self)

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let panel = NSPanel(
      contentRect: CGRect(x: 80, y: 80, width: 64, height: 64),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.alphaValue = 0
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.ignoresCycle, .transient]
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    guard let windowID = UInt32(exactly: panel.windowNumber) else {
      throw failure("Defi-owned probe surface has no WindowServer ID")
    }
    var original = CGRect.zero
    guard getBounds(connection, windowID, &original) == 0,
      original.origin.x.isFinite, original.origin.y.isFinite,
      original.width.isFinite, original.height.isFinite,
      original.width > 0, original.height > 0
    else {
      throw failure("Probe surface's initial bounds are unavailable or unusable")
    }
    var latenciesMS: [Double] = []
    for index in 0..<24 {
      var point = CGPoint(x: original.minX + CGFloat((index + 1) % 2), y: original.minY)
      let startedAt = ProcessInfo.processInfo.systemUptime
      let moveResult = withUnsafePointer(to: &point) { move(connection, windowID, $0) }
      var observed = CGRect.zero
      let boundsResult = getBounds(connection, windowID, &observed)
      guard moveResult == 0, boundsResult == 0,
        observed.width.isFinite, observed.height.isFinite,
        observed.width > 0, observed.height > 0,
        abs(observed.width - original.width) <= 0.5,
        abs(observed.height - original.height) <= 0.5,
        abs(observed.minX - point.x) <= 0.5,
        abs(observed.minY - point.y) <= 0.5
      else {
        var restorePoint = CGPoint(x: original.minX, y: original.minY)
        _ = withUnsafePointer(to: &restorePoint) { move(connection, windowID, $0) }
        throw failure(
          "SkyLight move did not converge; move=\(moveResult), bounds=\(boundsResult), "
            + "target=(\(point.x), \(point.y)), observed=(\(observed.minX), \(observed.minY))"
        )
      }
      latenciesMS.append((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }
    var restorePoint = CGPoint(x: original.minX, y: original.minY)
    let restoreResult = withUnsafePointer(to: &restorePoint) { move(connection, windowID, $0) }
    var restored = CGRect.zero
    let verifyRestore = getBounds(connection, windowID, &restored)
    guard restoreResult == 0, verifyRestore == 0,
      abs(restored.width - original.width) <= 0.5,
      abs(restored.height - original.height) <= 0.5,
      abs(restored.minX - original.minX) <= 0.5,
      abs(restored.minY - original.minY) <= 0.5
    else { throw failure("Probe surface did not return to its original bounds") }

    let ordered = latenciesMS.sorted()
    let median = ordered.count.isMultiple(of: 2)
      ? (ordered[ordered.count / 2 - 1] + ordered[ordered.count / 2]) / 2
      : ordered[ordered.count / 2]
    print("probe=DefiOwnedInvisiblePanel backend=SLSMoveWindow result=verified window=\(windowID)")
    print(String(format: "moveAndReadCount=%d medianMs=%.3f p95Ms=%.3f maxMs=%.3f",
                 ordered.count, median,
                 ordered[min(Int(Double(ordered.count) * 0.95), ordered.count - 1)],
                 ordered.last ?? 0))
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "DefiPrivateFrameProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
