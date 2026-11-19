import Foundation

/// Tests that order Defi's real panels on screen run in CI and with `DEFI_E2E=1`, never
/// on a developer's desktop, where `make verify` must stay invisible.
let desktopVisibleTestsRun =
  ProcessInfo.processInfo.environment["CI"] != nil
  || ProcessInfo.processInfo.environment["DEFI_E2E"] == "1"
