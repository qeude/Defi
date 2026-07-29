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
}
