import DefiCore
import DefiModel
import Testing

struct ParkingTests {
  private struct Display {
    let frame: Rect
    let visible: Rect
  }

  private let window = Rect(x: 300, y: 40, width: 1_200, height: 900)
  private let external = Display(
    frame: Rect(x: 0, y: 0, width: 2_560, height: 1_440),
    visible: Rect(x: 0, y: 30, width: 2_560, height: 1_367))
  private let builtInRight = Display(
    frame: Rect(x: 2_560, y: 0, width: 1_512, height: 982),
    visible: Rect(x: 2_560, y: 33, width: 1_512, height: 949))
  private let builtInStaircase = Display(
    frame: Rect(x: 2_560, y: -982, width: 1_512, height: 982),
    visible: Rect(x: 2_560, y: -949, width: 1_512, height: 949))

  private func park(_ frame: Rect, on display: Display, among others: [Display]) -> Rect {
    parkedFrame(frame, display: display.frame, visibleFrame: display.visible,
      otherDisplays: others.map(\.frame))
  }

  static let externalFrame = Rect(x: 0, y: 0, width: 2_560, height: 1_440)
  static let externalVisible = Rect(x: 0, y: 30, width: 2_560, height: 1_367)
  static let rightFrame = Rect(x: 2_560, y: 0, width: 1_512, height: 982)
  static let rightVisible = Rect(x: 2_560, y: 33, width: 1_512, height: 949)
  static let stairFrame = Rect(x: 2_560, y: -982, width: 1_512, height: 982)
  static let stairVisible = Rect(x: 2_560, y: -949, width: 1_512, height: 949)
  static let sideFrame = Rect(x: 2_560, y: 390, width: 1_512, height: 982)
  static let sideVisible = Rect(x: 2_560, y: 423, width: 1_512, height: 949)

  // display, visible frame, other displays -> parked origin of a 1200 x 900 window
  @Test(arguments: [
    // a single display parks at the side edge nearest the window, at its height
    (externalFrame, externalVisible, [], -1_199.0, 40.0),
    (externalFrame, externalVisible, [rightFrame], -1_199, 40),
    // the near edge touches the other display, so the far edge takes it
    (rightFrame, rightVisible, [externalFrame], 4_071, 40),
    // the staircase keeps each display on a free side edge, inside its own rows
    (externalFrame, externalVisible, [stairFrame], -1_199, 40),
    (stairFrame, stairVisible, [externalFrame], 4_071, -32),
    // the measured side-by-side arrangement parks where macOS keeps the windows
    (externalFrame, externalVisible, [sideFrame], -1_199, 40),
    (sideFrame, sideVisible, [externalFrame], 4_071, 423),
    (externalFrame, externalVisible, [Rect(x: 0, y: 1_440, width: 1_512, height: 982)], -1_199, 40),
  ] as [(Rect, Rect, [Rect], Double, Double)])
  func `Each display parks at a free side edge`(display: Rect, visible: Rect, others: [Rect], x: Double,
    y: Double) {
    #expect(parkedFrame(window, display: display, visibleFrame: visible, otherDisplays: others)
      == Rect(x: x, y: y, width: 1_200, height: 900))
  }

  @Test
  func `A window on the right half parks at the right edge`() {
    #expect(park(Rect(x: 2_000, y: 40, width: 1_200, height: 900), on: external, among: [])
      == Rect(x: 2_559, y: 40, width: 1_200, height: 900))
  }

  @Test
  func `Displays on both sides leave the bottom edge`() {
    let left = Rect(x: -2_560, y: 0, width: 2_560, height: 1_440)
    #expect(park(window, on: external, among: [Display(frame: left, visible: left), builtInRight])
      == Rect(x: 0, y: 1_365, width: 1_200, height: 900))
  }

  @Test
  func `A built-in on the left is isolated into the same staircase`() throws {
    let externalID = MonitorID(rawValue: 1), builtInID = MonitorID(rawValue: 2)
    let technical = isolatedDisplayArrangement([
      externalID: external.frame,
      builtInID: Rect(x: -1_512, y: 323, width: 1_512, height: 982),
    ], primary: externalID)
    #expect(technical == [externalID: external.frame, builtInID: builtInStaircase.frame],
      "so it parks like the staircase rows of the corner table")
  }

  @Test
  func `A boxed in display takes the candidate with the least overlap`() {
    func square(_ x: Double, _ y: Double) -> Display {
      let frame = Rect(x: x, y: y, width: 1_000, height: 1_000)
      return Display(frame: frame, visible: frame)
    }
    let neighbors = [
      square(0, 1_000), square(2_000, 1_000), square(1_000, 0),
      square(1_000, 2_000), square(2_000, 2_000),
    ]
    #expect(park(Rect(x: 0, y: 0, width: 500, height: 400),
      on: square(1_000, 1_000), among: neighbors)
      == Rect(x: 1_000, y: 1_968, width: 500, height: 400))
  }

  @Test
  func `Parked columns keep one place whatever the scroll offset`() {
    let id = WindowID(rawValue: 1)
    let parked = [-5_000.0, -1_200, 2_560, 9_000].map { x in
      continuousStripFramesForActiveWorkspace(
        [FrameAssignment(windowID: id, frame: Rect(x: x, y: 40, width: 1_200, height: 900))],
        viewport: external.visible,
        park: { park($0.frame, on: external, among: [builtInRight]) }
      ).frames[0].frame
    }
    #expect(parked == Array(
      repeating: Rect(x: -1_199, y: 40, width: 1_200, height: 900), count: 4))
  }

  @Test(arguments: [0.0, 1.0, 1.5])
  func `Columns showing more than a sliver stay in the strip`(overlap: Double) {
    let id = WindowID(rawValue: 1)
    let frame = Rect(x: -1_200 + overlap, y: 40, width: 1_200, height: 900)
    let plan = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(windowID: id, frame: frame)],
      viewport: external.frame, park: { park($0.frame, on: external, among: []) }
    )
    #expect(plan.frames[0].frame == (overlap > 1
      ? frame : Rect(x: -1_199, y: 40, width: 1_200, height: 900)))
    #expect(plan.parkedWindowIDs == (overlap > 1 ? [] : [id]))
  }

  @Test
  func `Each display parks outside the other display`() {
    for (first, second) in [(external, builtInRight), (external, builtInStaircase)] {
      for (display, other) in [(first, second), (second, first)] {
        let parked = park(window, on: display, among: [other])
        let leak = intersection(parked, other.frame)
        #expect(leak.width * leak.height == 0)
        #expect(intersection(parked, display.frame).width == 1)
      }
    }
  }

  private func intersection(_ lhs: Rect, _ rhs: Rect) -> (width: Double, height: Double) {
    (max(min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x), 0),
      max(min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y), 0))
  }
}
