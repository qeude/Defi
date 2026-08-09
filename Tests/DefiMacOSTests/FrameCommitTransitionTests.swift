import DefiModel
import Testing

@testable import DefiMacOS

struct FrameCommitTransitionTests {
  private let expectation = FrameCommitExpectation(
    from: Rect(x: 900, y: 80, width: 700, height: 600),
    target: Rect(x: 100, y: 40, width: 1_200, height: 900),
    issuedAt: 10,
    deadline: 10.8,
    observedAt: nil
  )

  @Test
  func intermediatePositionAndSizeCommitIsQuarantined() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_000, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      )
    )
  }

  @Test
  func geometryOutsideOwnCommitPathRemainsExternal() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_280, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ) == false
    )
  }

  @Test
  func mouseResizeBypassesCommitQuarantine() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 480, y: 60, width: 1_000, height: 760),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: true
      ) == false
    )
  }

  @Test
  func targetWithoutFreshObservationRemainsPending() {
    #expect(frameTransitionIsPending(target: expectation.target, observed: nil))
    #expect(
      frameTransitionIsPending(
        target: expectation.target,
        observed: expectation.target
      ) == false
    )
  }

  @Test
  func supersededFrameDebtStaysUntilTargetIsObserved() {
    let displaced = WindowID(rawValue: 1)
    let replacement = WindowID(rawValue: 2)
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)
    let observedElsewhere = Rect(x: 900, y: 40, width: 1_200, height: 900)

    let pending = unresolvedFrameDebtWindowIDs(
      pendingWindowIDs: [replacement],
      debtWindowIDs: [displaced],
      targetFrames: [displaced: target],
      observedFrames: [displaced: observedElsewhere]
    )
    #expect(pending == [displaced, replacement])

    let observed = unresolvedFrameDebtWindowIDs(
      pendingWindowIDs: [replacement],
      debtWindowIDs: [displaced],
      targetFrames: [displaced: target],
      observedFrames: [displaced: target]
    )
    #expect(observed == [replacement])
  }

  @Test
  func frameDebtPrunesConvergedAndRemovedWindows() {
    let converged = WindowID(rawValue: 1)
    let drifting = WindowID(rawValue: 2)
    let removed = WindowID(rawValue: 3)
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(
      prunedFrameDebtWindowIDs(
        debtWindowIDs: [converged, drifting, removed],
        liveWindowIDs: [converged, drifting],
        targetFrames: [converged: target, drifting: target],
        observedFrames: [
          converged: target,
          drifting: Rect(x: 900, y: 40, width: 1_200, height: 900),
        ]
      ) == [drifting]
    )
  }
}
