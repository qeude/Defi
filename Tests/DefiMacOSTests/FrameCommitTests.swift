import DefiCore
import DefiModel
import Darwin
import ApplicationServices
import Synchronization
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

  func testReverseRetargetUsesLastCompletedPositionDuringObservationLag() {
    let staleObserved = Rect(x: 900, y: 40, width: 800, height: 700)
    let completed = CGPoint(x: 100, y: 40)

    XCTAssertEqual(
      frameApplicationReference(
        pendingCorrection: nil,
        settlingReference: staleObserved,
        completedPosition: completed,
        previousTarget: Rect(x: 100, y: 40, width: 800, height: 700),
        nativeReference: nil
      ),
      Rect(x: 100, y: 40, width: 800, height: 700)
    )
  }

  func testFrameApplicationReferenceDoesNotReadNativeFrameWhenCached() {
    var nativeFrameWasRead = false

    _ = frameApplicationReference(
      pendingCorrection: Rect(x: 100, y: 40, width: 800, height: 700),
      settlingReference: nil,
      completedPosition: nil,
      previousTarget: nil,
      nativeReference: {
        nativeFrameWasRead = true
        return Rect(x: 900, y: 40, width: 800, height: 700)
      }()
    )

    XCTAssertFalse(nativeFrameWasRead)
  }

  func testDeferredFrameCorrectionSurvivesSnapshotRebuild() {
    let windowID = WindowID(rawValue: 42)
    let deferred = Rect(x: 900, y: 40, width: 800, height: 700)
    let fresh = Rect(x: 100, y: 40, width: 800, height: 700)

    XCTAssertEqual(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [:],
        debtWindowIDs: [windowID]
      )[windowID],
      deferred
    )
    XCTAssertEqual(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [windowID: fresh],
        debtWindowIDs: [windowID]
      )[windowID],
      fresh
    )
  }

  func testDisplayLinkActivationRejectsOlderGenerationAndStaleRequest() {
    XCTAssertTrue(
      displayLinkActivationIsCurrent(
        generation: 4,
        latestGeneration: 4,
        requestID: 8,
        latestRequestID: 8
      )
    )
    XCTAssertFalse(
      displayLinkActivationIsCurrent(
        generation: 3,
        latestGeneration: 4,
        requestID: 7,
        latestRequestID: 8
      )
    )
    XCTAssertFalse(
      displayLinkActivationIsCurrent(
        generation: 4,
        latestGeneration: 4,
        requestID: 7,
        latestRequestID: 8
      )
    )
  }

  func testDeferredParkingKeepsCoordinatorBusyUntilInvalidated() {
    let coordinator = AXFrameCoordinator()
    coordinator.deferredParkingWriteGenerations[WindowID(rawValue: 42)] = 3

    XCTAssertTrue(coordinator.isBusy)
    XCTAssertTrue(coordinator.hasPendingDeferredParkingWrites)
    XCTAssertTrue(coordinator.isBusy(for: WindowID(rawValue: 42)))
    XCTAssertFalse(coordinator.isBusy(for: WindowID(rawValue: 43)))

    coordinator.invalidate(reason: "mouse-gesture")

    XCTAssertFalse(coordinator.isBusy)
    XCTAssertFalse(coordinator.hasPendingDeferredParkingWrites)
  }

  func testStaticSettlementSamplesCanExitTheSlowLane() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS[42] = 12
    coordinator.latencySensitiveProcessIDs.insert(42)

    coordinator.recordProcessLatencySamples([42: 0])

    XCTAssertFalse(coordinator.latencySensitiveProcessIDs.contains(42))
  }

  func testExitedProcessesAreRemovedFromSlowLaneDiagnostics() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS = [42: 20, 43: 18]
    coordinator.latencySensitiveProcessIDs = [42, 43]

    coordinator.pruneProcessLatencyState(liveProcessIDs: [43])

    XCTAssertEqual(coordinator.slowProcessLatenciesMS, [43: 18])
  }

  func testStaleBatchDoesNotRecordLatencySample() {
    let accumulator = FrameResultAccumulator()
    accumulator.add(
      applied: 0,
      stale: 1,
      slowProcesses: [],
      processID: 42,
      processLatencyMS: 0.1,
      attempted: false,
      completedAt: 1
    )

    XCTAssertTrue(accumulator.result.processLatencySamplesMS.isEmpty)
  }

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

  func testSynchronousSizeFailureBlocksWarpReadiness() {
    XCTAssertFalse(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      )
    )
    XCTAssertTrue(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      )
    )
    XCTAssertFalse(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: true,
        asynchronousWriteSucceeded: false
      )
    )
    XCTAssertTrue(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: true
      )
    )
    XCTAssertTrue(
      frameSizeWriteSucceeded(
        sizeChanged: false,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      )
    )
  }

  func testAsynchronousLayoutRoutesNonAnimatedSizeWritesToCoordinator() {
    XCTAssertTrue(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false
      )
    )
    XCTAssertFalse(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false
      )
    )
  }

  func testDeferredFrameFocusRejectsNewerInputBeforeSubmission() {
    XCTAssertTrue(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 10
      )
    )
    XCTAssertFalse(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 11
      )
    )
    XCTAssertTrue(
      deferredFocusInputIsCurrent(
        requestedTimestamp: nil,
        latestUserInputTimestamp: 11
      )
    )
  }

  func testDeferredFrameFocusWaitsForPendingFrameDebt() {
    let target = WindowID(rawValue: 42)

    XCTAssertFalse(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target]
      )
    )
    XCTAssertTrue(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: []
      )
    )
  }

  func testDeferredFrameFocusRequiresTargetWriteOrObservedConvergence() {
    let target = WindowID(rawValue: 42)
    let frame = Rect(x: 10, y: 20, width: 300, height: 400)

    XCTAssertFalse(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: nil,
        targetFrame: frame
      )
    )
    XCTAssertTrue(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [target],
        observedFrame: nil,
        targetFrame: frame
      )
    )
    XCTAssertTrue(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: frame,
        targetFrame: frame
      )
    )
    XCTAssertFalse(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target],
        successfulWindowIDs: [target],
        observedFrame: frame,
        targetFrame: frame
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
      displayID: nil,
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false
    ) { result in
      XCTAssertFalse(result.completedLatest)
      XCTAssertTrue(result.successfulWindowIDs.isEmpty)
      completion.fulfill()
    }

    completeSupersededFrame(frame)

    wait(for: [completion], timeout: 0.1)
  }

  func testSuccessfulWriteReportsTheWindowThatWasWritten() {
    let coordinator = AXFrameCoordinator()
    let firstWindowID = WindowID(rawValue: 42)
    let secondWindowID = WindowID(rawValue: 43)
    let reportedWindowIDs = Mutex<[WindowID]>([])
    let frame = QueuedPositionFrame(
      generation: 1,
      source: "test",
      writes: [:],
      animatedWindowIDs: [],
      animationDuration: 0,
      refreshRateHz: 60,
      displayID: nil,
      initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false,
      successfulWrite: { windowID, _ in
        reportedWindowIDs.withLock { $0.append(windowID) }
      },
      completion: nil
    )

    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: firstWindowID,
      at: 10
    )
    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: firstWindowID,
      at: 11
    )
    coordinator.reportSuccessfulWrite(
      for: frame,
      windowID: secondWindowID,
      at: 12
    )

    XCTAssertEqual(
      reportedWindowIDs.withLock { $0 },
      [firstWindowID, secondWindowID]
    )
  }

  func testReplacementFramePreservesSupersededAsyncSizeWrite() {
    let element = AXUIElementCreateSystemWide()
    func write(
      size: CGSize,
      point: CGPoint = .zero,
      positionChanged: Bool = false,
      sizeChanged: Bool = true,
      synchronousSizeWriteSucceeded: Bool = false
    )
      -> AsyncPositionWrite
    {
      AsyncPositionWrite(
        element: element,
        application: element,
        processID: 42,
        fromPoint: .zero,
        point: point,
        fromSize: CGSize(width: 800, height: 600),
        size: size,
        positionChanged: positionChanged,
        sizeChanged: sizeChanged,
        animatesSize: false,
        synchronousSizeWriteSucceeded: synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
        isReentering: false,
        requiresVerifiedOffscreenWrite: false
      )
    }
    let carriedWindowID = WindowID(rawValue: 1)
    let replacementWindowID = WindowID(rawValue: 2)
    let result = frameWritesPreservingSupersededAsyncSizes(
      active: [carriedWindowID: write(size: CGSize(width: 900, height: 700))],
      pending: [:],
      replacement: [
        replacementWindowID: write(size: CGSize(width: 1_000, height: 700))
      ]
    )

    XCTAssertEqual(result[carriedWindowID]?.size.width, 900)
    XCTAssertEqual(result[replacementWindowID]?.size.width, 1_000)
  }

  func testPositionOnlyReplacementKeepsSameWindowAsyncSizeDebt() {
    let element = AXUIElementCreateSystemWide()
    func write(
      point: CGPoint,
      size: CGSize,
      positionChanged: Bool,
      sizeChanged: Bool
    ) -> AsyncPositionWrite {
      AsyncPositionWrite(
        element: element,
        application: element,
        processID: 42,
        fromPoint: .zero,
        point: point,
        fromSize: CGSize(width: 800, height: 600),
        size: size,
        positionChanged: positionChanged,
        sizeChanged: sizeChanged,
        animatesSize: false,
        synchronousSizeWriteSucceeded: !sizeChanged,
        enhancedUIWasEnabled: false,
        timeoutSeconds: 0.016,
        isParked: false,
        isReentering: false,
        requiresVerifiedOffscreenWrite: false
      )
    }
    let windowID = WindowID(rawValue: 1)
    let result = frameWritesPreservingSupersededAsyncSizes(
      active: [
        windowID: write(
          point: .zero,
          size: CGSize(width: 900, height: 700),
          positionChanged: false,
          sizeChanged: true
        )
      ],
      pending: [:],
      replacement: [
        windowID: write(
          point: CGPoint(x: 100, y: 40),
          size: CGSize(width: 800, height: 600),
          positionChanged: true,
          sizeChanged: false
        )
      ]
    )

    XCTAssertEqual(result[windowID]?.point, CGPoint(x: 100, y: 40))
    XCTAssertEqual(result[windowID]?.size, CGSize(width: 900, height: 700))
    XCTAssertTrue(result[windowID]?.positionChanged == true)
    XCTAssertTrue(result[windowID]?.sizeChanged == true)
    XCTAssertFalse(result[windowID]?.synchronousSizeWriteSucceeded == true)
  }

  func testRecentInternalWriteMatchesEveryRecordedComponent() {
    let sizeWrite = RecentInternalFrameWrite(
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      deadline: 20
    )
    let positionWrite = RecentInternalFrameWrite(
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      positionChanged: true,
      sizeChanged: false,
      deadline: 20
    )

    XCTAssertTrue(
      frameMatchesRecentInternalWrite(
        actual: sizeWrite.frame,
        write: sizeWrite
      )
    )
    XCTAssertTrue(
      frameMatchesRecentInternalWrite(
        actual: positionWrite.frame,
        write: positionWrite
      )
    )
    XCTAssertFalse(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 900, height: 700),
        write: sizeWrite
      )
    )
    XCTAssertFalse(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 100, y: 40, width: 1_200, height: 800),
        write: positionWrite
      )
    )
    XCTAssertFalse(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 1_200, height: 800),
        write: sizeWrite
      )
    )
  }

  func testRecentInternalWriteHistoryRetainsEveryLiveTarget() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    let first = Rect(x: 100, y: 40, width: 900, height: 700)
    let second = Rect(x: 300, y: 40, width: 900, height: 700)

    coordinator.recordInternalFrameWrite(
      first,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: false,
      now: 10
    )
    coordinator.recordInternalFrameWrite(
      second,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: false,
      now: 10.1
    )

    XCTAssertTrue(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: first,
        now: 10.2
      )
    )
    XCTAssertTrue(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: second,
        now: 10.2
      )
    )
  }

  func testInvalidationRetainsRecentInternalWriteHistory() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    let frame = Rect(x: 100, y: 40, width: 900, height: 700)

    coordinator.recordInternalFrameWrite(
      frame,
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )
    let element = AXUIElementCreateSystemWide()
    coordinator.activeWrites[windowID] = AsyncPositionWrite(
      element: element,
      application: element,
      processID: 42,
      fromPoint: .zero,
      point: .zero,
      fromSize: CGSize(width: 800, height: 600),
      size: CGSize(width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      animatesSize: false,
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
      isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
    coordinator.invalidate(reason: "display-change")

    XCTAssertTrue(coordinator.activeWrites.isEmpty)
    XCTAssertTrue(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: frame,
        now: 10.1
      )
    )
  }

  func testPruningRecentInternalWritesDropsClosedWindows() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    coordinator.recordInternalFrameWrite(
      Rect(x: 100, y: 40, width: 900, height: 700),
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )

    coordinator.pruneRecentInternalFrameWrites(liveWindowIDs: [])

    XCTAssertFalse(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 10.1
      )
    )
  }

  func testSuccessfulFrameWriteIntentKeepsPartialPositionWrite() {
    XCTAssertEqual(
      successfulFrameWriteIntent(
        positionChanged: true,
        positionApplied: true,
        sizeChanged: true,
        sizeApplied: false
      ),
      FrameWriteIntent(position: true, size: false)
    )
  }

  func testCompletedActiveSizeWriteIsNotCarriedIntoReplacement() {
    let coordinator = AXFrameCoordinator()
    let element = AXUIElementCreateSystemWide()
    let windowID = WindowID(rawValue: 42)
    coordinator.activeWrites[windowID] = AsyncPositionWrite(
      element: element,
      application: element,
      processID: 42,
      fromPoint: .zero,
      point: .zero,
      fromSize: CGSize(width: 800, height: 600),
      size: CGSize(width: 900, height: 700),
      positionChanged: false,
      sizeChanged: true,
      animatesSize: false,
      synchronousSizeWriteSucceeded: false,
      enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016,
      isParked: false,
      isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )

    coordinator.recordCompletedActiveSizeWrite(windowID: windowID)

    XCTAssertNil(coordinator.activeWrites[windowID])
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

  func testInitialSettlementRepairsOnlyStableDrift() {
    let generation: UInt64 = 4
    let first = InitialSettlementDriftSample(
      generation: generation,
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      observedAt: 10
    )

    XCTAssertFalse(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 100, y: 40, width: 1_000, height: 760),
        now: 10.1
      )
    )
    XCTAssertFalse(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: first.frame,
        now: 10.04
      )
    )
    XCTAssertTrue(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 101, y: 40, width: 900, height: 700),
        now: 10.08
      )
    )
  }

  func testUnchangedSettlementDriftPreservesFirstObservationTime() {
    let first = InitialSettlementDriftSample(
      generation: 4,
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      observedAt: 10
    )
    let unchanged = updatedInitialSettlementDriftSample(
      previous: first,
      generation: 4,
      actual: Rect(x: 101, y: 40, width: 900, height: 700),
      now: 10.03
    )
    let changed = updatedInitialSettlementDriftSample(
      previous: unchanged,
      generation: 4,
      actual: Rect(x: 100, y: 40, width: 1_000, height: 700),
      now: 10.04
    )

    XCTAssertEqual(unchanged.observedAt, 10)
    XCTAssertEqual(changed.observedAt, 10.04)
  }

  func testInitialSettlementSchedulesStableFollowUpBeforeExpiration() {
    XCTAssertEqual(
      initialSettlementFollowUpDelay(now: 12.1, deadline: 12.5)!,
      0.06,
      accuracy: 0.000_1
    )
    XCTAssertNil(initialSettlementFollowUpDelay(now: 12.48, deadline: 12.5))
    XCTAssertNil(initialSettlementFollowUpDelay(now: 12.5, deadline: 12.5))
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

  func testFocusOnlySynchronizationReusesCachedWindows() {
    XCTAssertEqual(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        allowsCachedRefresh: true
      ),
      []
    )
  }

  func testFrameNotificationRefreshesOnlyAffectedProcess() {
    XCTAssertEqual(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true,
        allowsCachedRefresh: true
      ),
      [202]
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
