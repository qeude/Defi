import DefiModel
import Testing

@testable import DefiDaemon

struct WorkspaceSwitchShiftTests {
  @Test func switchSlidesAlongTheMonitorsOwnStack() {
    let one = WorkspaceID(rawValue: "1"), two = WorkspaceID(rawValue: "2")
    let created = WorkspaceID(rawValue: "3")
    #expect(workspaceSwitchShift(from: one, to: two, order: [one, two], height: 900) == -900)
    #expect(workspaceSwitchShift(from: two, to: one, order: [one, two], height: 1_440) == 1_440)
    #expect(workspaceSwitchShift(from: two, to: created, order: [one, two], height: 900) == -900)
    #expect(workspaceSwitchShift(from: one, to: one, order: [one, two], height: 900) == nil)
  }
}
