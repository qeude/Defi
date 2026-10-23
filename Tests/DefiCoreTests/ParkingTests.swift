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

  @Test
  func `A single display parks in its bottom right corner above the Dock`() {
    #expect(park(window, on: external, among: [])
      == Rect(x: 2_559, y: 1_365, width: 1_200, height: 900))
  }

  @Test
  func `A display to the right moves external parking to the bottom left corner`() {
    #expect(park(window, on: external, among: [builtInRight])
      == Rect(x: -1_199, y: 1_365, width: 1_200, height: 900))
    #expect(park(window, on: builtInRight, among: [external])
      == Rect(x: 4_071, y: 950, width: 1_200, height: 900))
  }

  @Test
  func `A staircase keeps each display on a free bottom corner`() {
    #expect(park(window, on: external, among: [builtInStaircase])
      == Rect(x: -1_199, y: 1_365, width: 1_200, height: 900))
    #expect(park(window, on: builtInStaircase, among: [external])
      == Rect(x: 4_071, y: -32, width: 1_200, height: 900))
  }

  @Test
  func `The isolated staircase of a desk with the built-in on the left parks clear of both displays`() throws {
    let externalID = MonitorID(rawValue: 1), builtInID = MonitorID(rawValue: 2)
    let technical = isolatedDisplayArrangement([
      externalID: external.frame,
      builtInID: Rect(x: -1_512, y: 323, width: 1_512, height: 982),
    ], primary: externalID)
    #expect(technical[externalID] == external.frame)
    let builtInFrame = try #require(technical[builtInID])
    #expect(builtInFrame == Rect(x: 2_560, y: -982, width: 1_512, height: 982))
    let builtIn = Display(frame: builtInFrame, visible: Rect(
      x: builtInFrame.x, y: builtInFrame.y + 33, width: 1_512, height: 949))
    let parkedExternal = park(window, on: external, among: [builtIn])
    let parkedBuiltIn = park(window, on: builtIn, among: [external])
    #expect(parkedExternal == Rect(x: -1_199, y: 1_365, width: 1_200, height: 900))
    #expect(parkedBuiltIn == Rect(x: 4_071, y: -32, width: 1_200, height: 900))
    #expect(intersection(parkedExternal, builtInFrame).width
      * intersection(parkedExternal, builtInFrame).height == 0)
    #expect(intersection(parkedBuiltIn, external.frame).width
      * intersection(parkedBuiltIn, external.frame).height == 0)
  }

  @Test
  func `The measured side by side arrangement parks where macOS keeps the windows`() {
    let builtIn = Display(
      frame: Rect(x: 2_560, y: 390, width: 1_512, height: 982),
      visible: Rect(x: 2_560, y: 423, width: 1_512, height: 949))
    #expect(park(window, on: external, among: [builtIn])
      == Rect(x: -1_199, y: 1_365, width: 1_200, height: 900))
    #expect(park(window, on: builtIn, among: [external])
      == Rect(x: 4_071, y: 1_340, width: 1_200, height: 900))
  }

  @Test
  func `A display below keeps the bottom right corner clear`() {
    let below = Display(
      frame: Rect(x: 0, y: 1_440, width: 1_512, height: 982),
      visible: Rect(x: 0, y: 1_473, width: 1_512, height: 949))
    #expect(park(window, on: external, among: [below])
      == Rect(x: 2_559, y: 1_365, width: 1_200, height: 900))
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
        park: { park($0, on: external, among: [builtInRight]) }
      ).frames[0].frame
    }
    #expect(parked == Array(
      repeating: Rect(x: -1_199, y: 1_365, width: 1_200, height: 900), count: 4))
  }

  @Test(arguments: [0.0, 1.0, 1.5])
  func `Columns showing more than a sliver stay in the strip`(overlap: Double) {
    let id = WindowID(rawValue: 1)
    let frame = Rect(x: -1_200 + overlap, y: 40, width: 1_200, height: 900)
    let plan = continuousStripFramesForActiveWorkspace(
      [FrameAssignment(windowID: id, frame: frame)],
      viewport: external.frame, park: { park($0, on: external, among: []) }
    )
    #expect(plan.frames[0].frame == (overlap > 1
      ? frame : Rect(x: 2_559, y: 1_365, width: 1_200, height: 900)))
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
