import DefiIPC
import DefiModel
import Foundation
import Testing
@testable import DefiConfig
@testable import DefiMacOS

// Each probe touches a resource whose real use is harmless (computing a path, creating an
// element for this process), so the suite stays safe even if enforcement were missing.
@Suite(.enabled(if: RealResourceGuard.isEnforced, "make check sets DEFI_ISOLATED=1"))
struct RealResourceGuardTests {
  @Test func defaultSocketPathTraps() async {
    await #expect(processExitsWith: .failure) { _ = SocketPath.defaultURL }
  }

  @Test func defaultLockPathTraps() async {
    await #expect(processExitsWith: .failure) { _ = DaemonLockPath.defaultURL }
  }

  @Test func defaultConfigPathTraps() async {
    await #expect(processExitsWith: .failure) { _ = Config.defaultURL }
  }

  @Test func realAccessibilityElementTraps() async {
    await #expect(processExitsWith: .failure) {
      _ = accessibilityApplication(ProcessInfo.processInfo.processIdentifier)
    }
  }

  @Test func systemWideAccessibilityElementTraps() async {
    await #expect(processExitsWith: .failure) { _ = accessibilitySystemWide() }
  }
}
