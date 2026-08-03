import DefiCore
import DefiModel
import XCTest

final class LayoutTests: XCTestCase {
  private let settings = LayoutSettings()

  func testNewWindowInsertsAfterFocusedColumn() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)
    workspace.focusedColumn = 0
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: settings)

    XCTAssertEqual(
      workspace.columns.map(\.windows[0]),
      [WindowID(rawValue: 1), WindowID(rawValue: 3), WindowID(rawValue: 2)]
    )
    XCTAssertEqual(workspace.focusedColumn, 1)
  }

  func testIntrinsicSizeWindowStaysCenteredInTile() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(
      WindowID(rawValue: 1),
      width: .pixels(500),
      into: &workspace,
      settings: settings
    )
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "Simulator",
      title: "iPhone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      intrinsicSize: true
    )

    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: [window],
      settings: settings
    )

    XCTAssertEqual(
      diff.frames[0],
      FrameAssignment(
        windowID: WindowID(rawValue: 1),
        frame: Rect(x: 8, y: 88, width: 304, height: 624)
      )
    )
  }

  func testFocusScrollsOnlyEnoughForOverflow() throws {
    let compact = LayoutSettings(defaultColumnWidth: 0.72)
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: compact)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: compact)

    try focusColumn(.right, in: &workspace, settings: compact)
    workspace.scrollOffset = workspace.targetScrollOffset
    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_440, height: 900),
      settings: compact
    )

    XCTAssertEqual(workspace.targetScrollOffset, 0.44, accuracy: 0.001)
    XCTAssertEqual(diff.frames[1].frame.x, 407.2, accuracy: 0.001)
  }

  func testNeverCenteringPreservesVisibleColumn() {
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let columns = (1...4).map {
      Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5))
    }

    var workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: columns,
      focusedColumn: 1
    )
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      0,
      accuracy: 0.001
    )

    workspace.focusedColumn = 2
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      0.5,
      accuracy: 0.001
    )

    workspace.focusedColumn = 3
    workspace.scrollOffset = 0.5
    XCTAssertEqual(
      focusedColumnScrollOffset(workspace: workspace, viewport: viewport),
      1,
      accuracy: 0.001
    )
  }

  func testAlwaysCenteringCentersTarget() throws {
    let centered = LayoutSettings(
      defaultColumnWidth: 0.5,
      centerFocusedColumn: .always,
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: centered)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: centered)
    insertNewWindow(WindowID(rawValue: 3), into: &workspace, settings: centered)
    workspace.focusedColumn = 0

    try focusColumn(.right, in: &workspace, settings: centered)
    workspace.scrollOffset = workspace.targetScrollOffset
    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 900),
      settings: centered
    )

    XCTAssertEqual(workspace.targetScrollOffset, 0.25, accuracy: 0.001)
    XCTAssertEqual(diff.frames[1].frame.x, 250, accuracy: 0.001)
  }

  func testMoveFocusedWindowSwapsColumns() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try moveFocusedWindow(.left, in: &workspace, settings: settings)

    XCTAssertEqual(
      workspace.columns.map(\.windows[0]),
      [WindowID(rawValue: 2), WindowID(rawValue: 1)]
    )
    XCTAssertEqual(workspace.focusedColumn, 0)
  }

  func testRemovingLastWindowRepairsFocus() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    XCTAssertTrue(
      removeWindow(WindowID(rawValue: 2), from: &workspace, settings: settings)
    )
    XCTAssertEqual(workspace.columns.count, 1)
    XCTAssertEqual(workspace.focusedColumn, 0)
  }

  func testJoinAndUnjoinRoundTrip() throws {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(WindowID(rawValue: 1), into: &workspace, settings: settings)
    insertNewWindow(WindowID(rawValue: 2), into: &workspace, settings: settings)

    try joinFocusedWindow(.left, in: &workspace, settings: settings)
    XCTAssertEqual(workspace.columns.count, 1)
    XCTAssertEqual(
      workspace.columns[0].windows,
      [WindowID(rawValue: 1), WindowID(rawValue: 2)]
    )
    XCTAssertEqual(workspace.columns[0].focusedWindow, 1)

    try unjoinFocusedWindow(in: &workspace, settings: settings)
    XCTAssertEqual(workspace.columns.count, 2)
    XCTAssertEqual(workspace.columns[1].windows, [WindowID(rawValue: 2)])
    XCTAssertEqual(workspace.focusedColumn, 1)
  }

  func testFullscreenRestoresPixelWidth() {
    var column = Column(window: WindowID(rawValue: 1), width: .pixels(420))

    toggleFullscreen(of: &column, defaultWidth: 0.8)
    XCTAssertEqual(column.width, .fraction(1))
    XCTAssertEqual(column.fullscreenPreviousWidth, .pixels(420))

    toggleFullscreen(of: &column, defaultWidth: 0.8)
    XCTAssertEqual(column.width, .pixels(420))
    XCTAssertNil(column.fullscreenPreviousWidth)
  }

  func testCyclingForwardFromFullscreenUsesFirstPreset() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    let presets = [1.0, 0.33, 0.5, 0.66, 0.8]

    toggleFullscreen(of: &column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .next, presets: presets)

    XCTAssertEqual(column.width, .fraction(0.33))
    XCTAssertNil(column.fullscreenPreviousWidth)
  }

  func testCyclingBackwardFromFullscreenUsesLastPreset() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))
    let presets = [0.33, 0.5, 0.66, 0.8, 1.0]

    toggleFullscreen(of: &column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .previous, presets: presets)

    XCTAssertEqual(column.width, .fraction(0.8))
    XCTAssertNil(column.fullscreenPreviousWidth)
  }

  func testCyclingFromFullscreenWithOnlyFullWidthPresetDoesNothing() {
    var column = Column(window: WindowID(rawValue: 1), width: .fraction(0.5))

    toggleFullscreen(of: &column, defaultWidth: 0.8)
    cycleWidth(of: &column, direction: .previous, presets: [1.0])

    XCTAssertEqual(column.width, .fraction(1))
    XCTAssertEqual(column.fullscreenPreviousWidth, .fraction(0.5))
  }

  func testSpeculativeNavigationSettlementWaitsPastVisualAnimation() {
    XCTAssertEqual(
      speculativeNavigationSettlementDelay(animationDuration: 0.035),
      0.075,
      accuracy: 0.000_1
    )
    XCTAssertEqual(
      speculativeNavigationSettlementDelay(animationDuration: 0.1),
      0.12,
      accuracy: 0.000_1
    )
  }

  func testFrameBatchSkipsUnchangedAssignments() {
    let first = FrameAssignment(
      windowID: WindowID(rawValue: 1),
      frame: Rect(x: 0, y: 0, width: 500, height: 800)
    )
    let second = FrameAssignment(
      windowID: WindowID(rawValue: 2),
      frame: Rect(x: 500, y: 0, width: 500, height: 800)
    )
    let moved = FrameAssignment(
      windowID: WindowID(rawValue: 2),
      frame: Rect(x: 600, y: 0, width: 500, height: 800)
    )

    let batch = planFrameBatch(previous: [first, second], next: [first, moved])

    XCTAssertEqual(batch.frames, [moved])
    XCTAssertEqual(batch.stats.plannedWrites, 1)
    XCTAssertEqual(batch.stats.skippedUnchanged, 1)
  }

  func testParkingUsesStableUniqueSlots() {
    let diff = parkOffscreen([
      WindowID(rawValue: 1),
      WindowID(rawValue: 2),
    ])

    XCTAssertEqual(diff.frames[0].frame, Rect(x: -10_000, y: -10_000, width: 1, height: 1))
    XCTAssertEqual(diff.frames[1].frame, Rect(x: -10_000, y: -10_020, width: 1, height: 1))
  }

  func testContinuousStripAnchorsEveryOffscreenColumnAndPrefetchesNeighbors() {
    let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let frames = (0..<10).map { index in
      FrameAssignment(
        windowID: WindowID(rawValue: UInt64(index + 1)),
        frame: Rect(
          x: Double(index - 5) * 500,
          y: 0,
          width: 500,
          height: 700
        )
      )
    }

    let plan = continuousStripFramesForActiveWorkspace(
      frames,
      viewport: viewport,
      prefetchViewports: 0,
      prefetchColumnsPerSide: 1
    )
    let byID = Dictionary(
      uniqueKeysWithValues: plan.frames.map { ($0.windowID, $0.frame) }
    )

    XCTAssertEqual(byID[WindowID(rawValue: 4)]?.x, -499)
    XCTAssertEqual(byID[WindowID(rawValue: 3)]?.x, -499)
    XCTAssertEqual(byID[WindowID(rawValue: 3)]?.y, 0)
    XCTAssertEqual(byID[WindowID(rawValue: 9)]?.x, 999)
    XCTAssertEqual(byID[WindowID(rawValue: 10)]?.x, 999)
    XCTAssertEqual(byID[WindowID(rawValue: 10)]?.y, 0)
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 3)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 10)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 4)))
    XCTAssertTrue(plan.parkedWindowIDs.contains(WindowID(rawValue: 9)))
    XCTAssertEqual(
      plan.visibilityByWindowID[WindowID(rawValue: 4)],
      .prefetched
    )
    XCTAssertEqual(
      plan.visibilityByWindowID[WindowID(rawValue: 3)],
      .parked
    )
  }

  func testParkingResolverAvoidsNeighboringMonitor() {
    let owner = Rect(x: 0, y: 0, width: 1_000, height: 700)
    let leftNeighbor = Rect(x: -1_000, y: 0, width: 1_000, height: 700)
    let placement = resolveParkingPlacement(
      for: Rect(x: 0, y: 0, width: 500, height: 700),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor],
      preferredSide: .left
    )

    XCTAssertEqual(placement.side, .right)
    XCTAssertEqual(
      placement.frame,
      Rect(x: 999, y: 0, width: 500, height: 700)
    )
  }

  func testParkingResolverUsesVerticalLaneAroundStaggeredDisplays() {
    let owner = Rect(x: 1_000, y: 0, width: 1_000, height: 1_000)
    let leftNeighbor = Rect(x: 0, y: 400, width: 1_000, height: 500)
    let rightNeighbor = Rect(x: 2_000, y: 0, width: 1_000, height: 500)
    let placement = resolveParkingPlacement(
      for: Rect(x: 1_000, y: 0, width: 500, height: 300),
      ownerFrame: owner,
      allMonitorFrames: [owner, leftNeighbor, rightNeighbor],
      preferredSide: .left
    )

    XCTAssertGreaterThan(
      verticalIntersection(placement.frame, owner),
      0
    )
    XCTAssertEqual(intersectionArea(placement.frame, leftNeighbor), 0)
    XCTAssertEqual(intersectionArea(placement.frame, rightNeighbor), 0)
  }

  func testEachViewportProducesItsOwnMonitorSizedLayout() {
    let noGaps = LayoutSettings(
      defaultColumnWidth: 0.8,
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [Column(window: WindowID(rawValue: 1), width: .fraction(0.8))]
    )

    let laptop = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_500, height: 900),
      settings: noGaps
    ).frames[0].frame
    let external = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 1_500, y: 30, width: 2_560, height: 1_362),
      settings: noGaps
    ).frames[0].frame

    XCTAssertEqual(laptop, Rect(x: 0, y: 0, width: 1_200, height: 900))
    XCTAssertEqual(
      external,
      Rect(x: 1_500, y: 30, width: 2_048, height: 1_362)
    )
  }

  func testScrollAnimationUsesEaseOutCubicAndFinishesExactly() {
    XCTAssertEqual(animatedScalar(from: 0, to: 1, elapsed: 0, duration: 0.08), 0)
    XCTAssertEqual(
      animatedScalar(from: 0, to: 1, elapsed: 0.04, duration: 0.08),
      0.875,
      accuracy: 0.000_1
    )
    XCTAssertEqual(animatedScalar(from: 0, to: 1, elapsed: 0.08, duration: 0.08), 1)
  }

  func testCriticallyDampedSpringConvergesWithoutOvershoot() {
    var value = 0.0
    var velocity = 0.0
    for _ in 0..<90 {
      let step = criticallyDampedSpringStep(
        value: value,
        target: 500,
        velocity: velocity,
        deltaTime: 1 / 120,
        response: 0.18
      )
      XCTAssertGreaterThanOrEqual(step.value, value)
      XCTAssertLessThanOrEqual(step.value, 500)
      value = step.value
      velocity = step.velocity
    }
    XCTAssertEqual(value, 500, accuracy: 0.01)
    XCTAssertEqual(velocity, 0, accuracy: 0.5)
  }

  func testCompletedFrameSpringKeepsMultipleMonotonicSamples() {
    let at120Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 120
    )
    let at60Hz = completedFrameSpringProgresses(
      duration: 0.035,
      refreshRateHz: 60
    )

    XCTAssertEqual(at120Hz.count, 4)
    XCTAssertEqual(at60Hz.count, 2)
    XCTAssertEqual(at120Hz.first ?? 0, 0.247, accuracy: 0.002)
    XCTAssertGreaterThan(at120Hz.last ?? 0, 0.85)
    XCTAssertLessThan(at120Hz.last ?? 1, 1)
    XCTAssertEqual(at120Hz, at120Hz.sorted())
  }

  func testAdaptiveFrameLimitAvoidsMultiplyingSlowAXCalls() {
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.004,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      4
    )
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.012,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      1
    )
    XCTAssertEqual(
      adaptiveIntermediateFrameLimit(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      1
    )
  }

  func testSpringProgressAnticipatesAXCompletionLatency() {
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.002,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      0
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.018,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      2
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.030,
        refreshRateHz: 120,
        availableIntermediateFrames: 4
      ),
      3
    )
    XCTAssertEqual(
      anticipatedSpringProgressIndex(
        predictedFrameLatency: 0.051,
        refreshRateHz: 120,
        availableIntermediateFrames: 4,
        maximumIndex: 1
      ),
      1
    )
  }

  func testCompletedAXFrameSchedulesNextWriteAfterDisplayInterval() {
    XCTAssertEqual(
      nextCompletedFrameDispatchDeadline(
        completedAt: 10,
        refreshRateHz: 120
      ),
      10 + 1.0 / 120,
      accuracy: 0.000_001
    )
    XCTAssertEqual(
      nextCompletedFrameDispatchDeadline(
        completedAt: 10,
        refreshRateHz: 60
      ),
      10 + 1.0 / 60,
      accuracy: 0.000_001
    )
  }

  func testSlowCompletedFrameSkipsIntermediateThatCannotFitBudget() {
    XCTAssertTrue(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.024,
        budget: 0.06,
        completedIntermediateFrames: 1
      )
    )
    XCTAssertFalse(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.029,
        predictedFrameLatency: 0.032,
        budget: 0.06,
        completedIntermediateFrames: 1
      )
    )
    XCTAssertTrue(
      shouldEmitAnotherIntermediateFrame(
        elapsed: 0.059,
        predictedFrameLatency: 0.5,
        budget: 0.06,
        completedIntermediateFrames: 0
      )
    )
  }

  func testSlowCompletedSampleStopsFurtherAXFrames() {
    XCTAssertTrue(
      completedFrameSupportsAnotherSample(
        duration: 0.006,
        refreshRateHz: 120
      )
    )
    XCTAssertFalse(
      completedFrameSupportsAnotherSample(
        duration: 0.020,
        refreshRateHz: 120
      )
    )
  }

  func testFinalAXFrameIsDispatchedEarlyEnoughToFinishOnAnimationDeadline() {
    XCTAssertEqual(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.012
      ),
      0.023,
      accuracy: 0.000_1
    )
    XCTAssertEqual(
      anticipatedFinalFrameDispatchDelay(
        animationDuration: 0.035,
        predictedFrameLatency: 0.050
      ),
      0
    )
  }

  func testDisplayedFrameRebaseUsesMedianAndRejectsOutliers() {
    XCTAssertEqual(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [-82, -80, 4_000],
        maximumAbsoluteDelta: 1_000
      ),
      DisplayedScalarRebase(value: 420, delta: -80)
    )
    XCTAssertNil(
      rebaseScalarToDisplayedFrames(
        logicalValue: 500,
        expectedMinusDisplayedDeltas: [0.1, 4_000],
        maximumAbsoluteDelta: 1_000
      )
    )
  }

  private func intersectionArea(_ lhs: Rect, _ rhs: Rect) -> Double {
    max(
      min(lhs.x + lhs.width, rhs.x + rhs.width) - max(lhs.x, rhs.x),
      0
    ) * max(
      min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
      0
    )
  }

  private func verticalIntersection(_ lhs: Rect, _ rhs: Rect) -> Double {
    max(
      min(lhs.y + lhs.height, rhs.y + rhs.height) - max(lhs.y, rhs.y),
      0
    )
  }
}
