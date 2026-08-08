import DefiCore
import DefiModel
import Darwin
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

  func testCursorWarpRequiresSuccessfulTargetFrameWrite() {
    let target = WindowID(rawValue: 2)
    let sibling = WindowID(rawValue: 3)
    let failed = FrameWriteCompletion(
      completedLatest: true,
      attemptedWindowIDs: [target, sibling],
      successfulWindowIDs: [sibling]
    )
    let succeeded = FrameWriteCompletion(
      completedLatest: true,
      attemptedWindowIDs: [target, sibling],
      successfulWindowIDs: [target, sibling]
    )

    XCTAssertNil(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: failed
      )
    )
    XCTAssertEqual(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: succeeded
      ),
      10
    )
  }

  func testCursorWarpAllowsObservedConvergenceAfterFailedWrite() {
    let target = Rect(x: 100, y: 40, width: 800, height: 700)

    XCTAssertFalse(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: Rect(x: 900, y: 40, width: 800, height: 700),
        targetFrame: target
      )
    )
    XCTAssertTrue(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: target,
        targetFrame: target
      )
    )
  }

  func testDisplacedQueuedFrameCompletesAsSuperseded() {
    let completion = expectation(description: "superseded completion")
    let frame = QueuedPositionFrame(
      generation: 1,
      source: "test",
      writes: [:],
      animatedWindowIDs: [],
      animationDuration: 0,
      refreshRateHz: 60,
      stagesVisibleBeforeParking: false
    ) { result in
      XCTAssertFalse(result.completedLatest)
      XCTAssertTrue(result.successfulWindowIDs.isEmpty)
      completion.fulfill()
    }

    completeSupersededFrame(frame)

    wait(for: [completion], timeout: 0.1)
  }

  func testInitialWindowCommitUsesShortQuarantineForFastRetries() {
    XCTAssertEqual(
      frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: true
      ),
      0.18,
      accuracy: 0.000_1
    )
    XCTAssertEqual(
      frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: false
      ),
      0.8,
      accuracy: 0.000_1
    )
  }

  func testInitialWindowCommitStillCoversAnimation() {
    XCTAssertEqual(
      frameCommitQuarantineDuration(
        animationDuration: 0.35,
        initialFrameSettlement: true
      ),
      0.47,
      accuracy: 0.000_1
    )
  }

  func testInitialSettlementRepairsPositionOrSizeDrift() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    XCTAssertFalse(initialFrameNeedsRepair(actual: target, target: target))
    XCTAssertTrue(
      initialFrameNeedsRepair(
        actual: Rect(x: 140, y: 40, width: 1_200, height: 900),
        target: target
      )
    )
    XCTAssertTrue(
      initialFrameNeedsRepair(
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        target: target
      )
    )
  }

  func testInitialSettlementStaysArmedAfterMatchingFrame() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    XCTAssertEqual(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 10,
        deadline: 12.5
      ),
      .stable
    )
    XCTAssertEqual(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 12.5,
        deadline: 12.5
      ),
      .expired
    )
  }

  func testInitialSettlementRepairRequiresCurrentGenerationAndIdleMouse() {
    XCTAssertTrue(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      )
    )
    XCTAssertFalse(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 5,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      )
    )
    XCTAssertFalse(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: true,
        leftMouseButtonDown: false,
        animationRunning: false
      )
    )
    XCTAssertFalse(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: true,
        animationRunning: false
      )
    )
    XCTAssertFalse(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: true
      )
    )
  }

  func testWindowEventsUseIncrementalRefreshOnlyWithStablePIDContext() {
    let processIDs: Set<pid_t> = [101, 202]

    XCTAssertEqual(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      ),
      processIDs
    )
    XCTAssertNil(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: false,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      )
    )
    XCTAssertNil(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: true,
        processIDs: processIDs
      )
    )
    XCTAssertNil(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: []
      )
    )
  }

  func testIncrementalRefreshIncludesCoalescedFrameProcess() {
    XCTAssertEqual(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedProcessIDs: [202]
      ),
      [101, 202]
    )
  }

  func testCoalescedFrameProcessDuringGestureDoesNotRequireTopologyEvent() {
    XCTAssertEqual(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true
      ),
      [202]
    )
  }

  func testCoalescedFrameProcessOutsideGestureUsesFullRefresh() {
    XCTAssertNil(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202]
      )
    )
  }

  func testCoalescedMouseResizeForcesFullRefresh() {
    XCTAssertNil(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedEventRequiresFullSnapshot: true
      )
    )
  }

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

  func testOnlyIncomingWorkspaceWritesSuppressNativePositionAnimation() {
    XCTAssertTrue(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: false,
        isIntermediate: false
      )
    )
    XCTAssertFalse(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: true,
        isIntermediate: false
      )
    )
    XCTAssertFalse(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: false,
        isParked: false,
        isIntermediate: false
      )
    )
    XCTAssertFalse(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: false,
        isIntermediate: true
      )
    )
  }

  func testDeferredFocusOnlyAppliesToCurrentSelection() {
    let target = WindowID(rawValue: 1)

    XCTAssertTrue(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: target
      )
    )
    XCTAssertFalse(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: WindowID(rawValue: 2)
      )
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

  func testAnimationLanesKeepFastProcessesInterpolated() {
    let fast = WindowID(rawValue: 1)
    let slow = WindowID(rawValue: 2)

    XCTAssertEqual(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slow],
        processIDs: [fast: 101, slow: 202],
        reenteringWindowIDs: [],
        finalOnlyProcessIDs: [202]
      ),
      FrameAnimationLanePlan(
        interpolatedWindowIDs: [fast],
        finalOnlyWindowIDs: [slow],
        stagedFinalOnlyReentryWindowIDs: []
      )
    )
  }

  func testFinalOnlyReentryKeepsVerifiedStagingWrite() {
    let fast = WindowID(rawValue: 1)
    let slowReentry = WindowID(rawValue: 2)

    XCTAssertEqual(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slowReentry],
        processIDs: [fast: 101, slowReentry: 202],
        reenteringWindowIDs: [slowReentry],
        finalOnlyProcessIDs: [202]
      ).stagedFinalOnlyReentryWindowIDs,
      [slowReentry]
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
