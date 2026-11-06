import CoreGraphics
import DefiModel
import Testing

@testable import DefiDaemon

struct ScrollPanTests {
  // A laptop below-left of a taller external display, as in a staircase arrangement.
  private let displays: [(MonitorID, Rect)] = [
    (MonitorID(rawValue: 1), Rect(x: 0, y: 0, width: 2560, height: 1440)),
    (MonitorID(rawValue: 2), Rect(x: -1512, y: 1440, width: 1512, height: 982)),
  ]

  @Test
  func `A gesture moves the display under the pointer, and only that one`() {
    #expect(scrollPanMonitorID(at: CGPoint(x: 1280, y: 700), displays: displays) == MonitorID(rawValue: 1))
    #expect(scrollPanMonitorID(at: CGPoint(x: -700, y: 2000), displays: displays) == MonitorID(rawValue: 2))
    #expect(scrollPanMonitorID(at: CGPoint(x: -700, y: 700), displays: displays) == nil)
  }

  @Test
  func `The strip shift rubber-bands past the ends and the workspace stack holds one step`() {
    let pan = ScrollPan(id: 1, vertical: true, monitorID: MonitorID(rawValue: 1),
      workspaceID: WorkspaceID(rawValue: "a"), viewport: Rect(x: 0, y: 0, width: 2560, height: 1440),
      start: 0, scale: 1440 / scrollPanWorkspaceTravel, bounds: -1440...0, dimension: 72, stiffness: 0.5,
      rest: 0, stripWidth: 2560, workspaceHeight: 1440, steps: 0...1)
    #expect(pan.shift(travel: -100) == -100 * 1440 / scrollPanWorkspaceTravel)
    // Pulling up from the top workspace stays within Niri's 5% band.
    #expect(pan.shift(travel: 10_000) < 72)
    #expect(pan.shift(travel: -10_000) > -1440 - 72)
    #expect(abs(scrollPanProjection - 0.333) < 0.001)
  }
}
