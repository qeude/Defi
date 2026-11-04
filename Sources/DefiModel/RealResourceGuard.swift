import Foundation

/// Stops an isolated test the moment Defi code reaches a real macOS resource.
///
/// `make check` runs with `DEFI_ISOLATED=1`. Under it, every call site that would touch the
/// user's session — Accessibility elements and writes, event taps, global hotkeys, display
/// configuration, AppKit panels, and the daemon's default lock, socket, config and session
/// paths — traps with the resource name, so a missing test double fails loudly instead of
/// reaching the running Defi daemon or the desktop.
public enum RealResourceGuard {
  public static let environmentKey = "DEFI_ISOLATED"
  public static let isEnforced = ProcessInfo.processInfo.environment[environmentKey] == "1"

  @inline(__always)
  public static func check(_ resource: @autoclosure () -> String) {
    guard isEnforced else { return }
    let caller = Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: "\n")
    fatalError("\(environmentKey)=1: Defi touched the real resource \(resource()); inject a test double\n\(caller)")
  }
}
