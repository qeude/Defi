import DefiModel
import Testing
@testable import DefiMacOS

struct UserInputTrackingTests {
  @Test
  func `An app activation at the same instant as the latest input is kept`() {
    let tracker = UserInputTracker()
    tracker.record(timestamp: 5)
    tracker.recordApplicationActivation(processID: 42, at: 5)
    #expect(tracker.pendingApplicationActivation(frontmostProcessID: 42, at: 5)?.processID == 42)
  }

  @Test
  func `A command's own capture is not newer input that recovers focus`() {
    let tracker = UserInputTracker()
    tracker.recordCapturedCommand(at: 5)
    #expect(tracker.focusRecoveryTarget(
      after: 5, fallbackWindowID: WindowID(rawValue: 1), fallbackProcessID: 42) == nil)
  }
}
