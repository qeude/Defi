import DefiCore
import DefiModel
import XCTest

@testable import DefiMacOS

final class FrameCommitTests: XCTestCase {
  private let expectation = FrameCommitExpectation(
    from: Rect(x: 900, y: 40, width: 800, height: 700),
    target: Rect(x: 100, y: 40, width: 800, height: 700),
    issuedAt: 10,
    deadline: 10.65,
    observedAt: nil
  )

  func testWorkspaceSwitchPlacesVisibleWindowsBeforeParkingOldWorkspace() {
    let visible = WindowID(rawValue: 1)
    let parked = Set([WindowID(rawValue: 2), WindowID(rawValue: 3)])
    let all = parked.union([visible])

    XCTAssertEqual(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: true
      ),
      [Set([visible]), parked]
    )
    XCTAssertEqual(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: false
      ),
      [all]
    )
  }

  func testExpectedHorizontalCommitLagIsQuarantined() {
    XCTAssertTrue(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      )
    )
  }

  func testLateIntermediateRollbackRemainsQuarantinedAfterTargetWasObserved() {
    var observedExpectation = expectation
    observedExpectation.observedAt = 10.2

    XCTAssertTrue(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 260, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: observedExpectation,
        now: 10.5,
        leftMouseButtonDown: false
      )
    )
  }

  func testExpiredOrExternalMovementIsNotQuarantined() {
    XCTAssertFalse(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.7,
        leftMouseButtonDown: false
      )
    )
    XCTAssertFalse(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 1_400, y: 180, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      )
    )
    XCTAssertFalse(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: true
      )
    )
  }

  func testOnePixelStripAnchorsRequireVerifiedOffscreenWrites() {
    let monitor = Rect(x: 0, y: 0, width: 1_512, height: 900)

    XCTAssertTrue(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      )
    )
    XCTAssertTrue(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -1_203, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      )
    )
    XCTAssertFalse(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -905, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      )
    )
  }

  func testNeighboringMonitorPreventsFalseSliverClassification() {
    XCTAssertFalse(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [
          Rect(x: 0, y: 0, width: 1_512, height: 900),
          Rect(x: 1_512, y: 0, width: 1_920, height: 1_080),
        ]
      )
    )
  }

  func testAXLatencyClassificationUsesHysteresis() {
    XCTAssertFalse(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 11.9
      )
    )
    XCTAssertTrue(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 12
      )
    )
    XCTAssertTrue(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 7
      )
    )
    XCTAssertFalse(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 6.9
      )
    )
  }

  func testSkippedWindowKeepsPreviousTargetUntilSettlement() {
    let skipped = WindowID(rawValue: 1)
    let fast = WindowID(rawValue: 2)
    let previous: [WindowID: Rect] = [
      skipped: Rect(x: 10, y: 0, width: 400, height: 700),
      fast: Rect(x: 420, y: 0, width: 400, height: 700),
    ]
    let next = frameTargetsPreservingSkippedWindows(
      previous: previous,
      assignments: [
        FrameAssignment(
          windowID: skipped,
          frame: Rect(x: -390, y: 0, width: 400, height: 700)
        ),
        FrameAssignment(
          windowID: fast,
          frame: Rect(x: 20, y: 0, width: 400, height: 700)
        ),
      ],
      skippedWindowIDs: [skipped]
    )

    XCTAssertEqual(next[skipped], previous[skipped])
    XCTAssertEqual(next[fast], Rect(x: 20, y: 0, width: 400, height: 700))
  }

  func testSkippedWindowKeepsPreviousParkingStateUntilSettlement() {
    let skipped = WindowID(rawValue: 1)
    let fast = WindowID(rawValue: 2)

    XCTAssertEqual(
      hiddenWindowsPreservingSkippedWindows(
        previous: [skipped],
        desired: [fast],
        skippedWindowIDs: [skipped]
      ),
      [skipped, fast]
    )
  }

  func testRibbonNavigationNeverPlansSizeWrites() {
    XCTAssertEqual(
      frameWriteIntent(
        reference: Rect(x: 800, y: 0, width: 600, height: 700),
        target: Rect(x: 100, y: 0, width: 1_000, height: 900),
        positionsOnly: true
      ),
      FrameWriteIntent(position: true, size: false)
    )
  }

  func testFrameAnimationInterpolatesPositionAndSize() {
    XCTAssertEqual(
      interpolatedFrame(
        from: Rect(x: 100, y: 40, width: 600, height: 700),
        to: Rect(x: 40, y: 20, width: 1_000, height: 800),
        progress: 0.25
      ),
      Rect(x: 85, y: 35, width: 700, height: 725)
    )
  }
}
