import ApplicationServices
import Darwin
import DefiCore
import DefiModel
import Numerics
import Synchronization
import Testing

@testable import DefiMacOS

struct FrameCommitTests {
  @Test func completedTargetDoesNotWaitForSlowSibling() {
    let target = WindowID(rawValue: 1)
    let sibling = WindowID(rawValue: 2)
    let coordinator = AXFrameCoordinator()
    coordinator.latestGeneration = 10
    coordinator.activeWindowIDs = [target, sibling]
    #expect(coordinator.pendingWindowIDs == [target, sibling])

    coordinator.successfulFinalWritesByGeneration[10] = [target]
    #expect(coordinator.pendingWindowIDs == [sibling])
    #expect(coordinator.isBusy(for: target) == false)
    #expect(coordinator.isBusy(for: sibling))

    // A final position must still wait for its deferred size write.
    coordinator.activeAnimatedSizeWindowIDs = [target]
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.activeAnimatedSizeWindowIDs = []
    coordinator.activeWrites[target] = makeMotionWrite(fromX: 900, toX: 100, sizeChanged: true)
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.recordCompletedActiveSizeWrite(windowID: target)
    #expect(coordinator.pendingWindowIDs == [sibling])
    coordinator.deferredParkingWriteGenerations[target] = 10
    #expect(coordinator.pendingWindowIDs == [target, sibling])
    coordinator.deferredParkingWriteGenerations = [:]

    // Completion of an older generation cannot release a replacement target.
    coordinator.latestGeneration = 11
    #expect(coordinator.pendingWindowIDs == [target, sibling])
  }

  @Test(arguments: [-100.0, 900.0])
  func interruptedRibbonStartsAtCompletedPositionAndKeepsOnlyForwardVelocity(targetX: Double) {
    let windowID = WindowID(rawValue: 1)
    let coordinator = AXFrameCoordinator()
    coordinator.recordCompletedPosition(CGPoint(x: 400, y: 40), windowID: windowID)
    coordinator.retargetHorizontalVelocities[windowID] = -500
    let frame = QueuedPositionFrame(
      generation: 2, source: "test-retarget",
      writes: [windowID: makeMotionWrite(fromX: 900, toX: targetX)],
      animatedWindowIDs: [windowID], animationDuration: 0.18,
      refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
    let rebased = coordinator.rebaseFrameToCompletedPositionsLocked(frame)
    #expect(rebased.frame.writes[windowID]?.fromPoint.x == 400)
    #expect(rebased.frame.writes[windowID]?.point.x == CGFloat(targetX))
    #expect(rebased.frame.initialProgressVelocity == (targetX < 400 ? 1 : 0))
    let samples = completedFrameSpringSamples(
      duration: 0.18, refreshRateHz: 120,
      initialVelocity: rebased.frame.initialProgressVelocity
    )
    let positions = samples.map { 400 + (targetX - 400) * $0.progress }
    #expect(positions.allSatisfy { $0 >= min(400, targetX) && $0 <= max(400, targetX) })
    #expect(positions == positions.sorted(by: targetX < 400 ? (>) : (<)))
  }

  private func makeMotionWrite(
    fromX: Double, toX: Double, sizeChanged: Bool = false
  ) -> AsyncPositionWrite {
    // Handles only: these tests never read or mutate the real desktop.
    let element = AXUIElementCreateSystemWide()
    return AsyncPositionWrite(
      element: element, application: element, processID: 42,
      fromPoint: CGPoint(x: fromX, y: 40), point: CGPoint(x: toX, y: 40),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 900, height: 700),
      positionChanged: true, sizeChanged: sizeChanged, animatesSize: false,
      synchronousSizeWriteSucceeded: !sizeChanged, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false, isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
  }

  private let expectation = FrameCommitExpectation(
    from: Rect(x: 900, y: 40, width: 800, height: 700),
    target: Rect(x: 100, y: 40, width: 800, height: 700),
    issuedAt: 10,
    deadline: 10.65,
    observedAt: nil
  )

  @Test
  func `Animation lane keeps only its latest pending sample`() {
    var lane = LatestAnimationSampleState<Int>()

    #expect(lane.submit(1).startsDrain)
    #expect(lane.submit(2).startsDrain == false)
    let latest = lane.submit(3)
    #expect(latest.startsDrain == false)
    #expect(latest.displaced == 2)
    #expect(lane.takeNext() == 3)
    #expect(lane.takeNext() == nil)
    #expect(lane.isRunning == false)
  }

  @Test
  func `Workspace animation accepts an adaptively sampled AX lane`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS[42] = 12
    coordinator.predictedProcessLatencyMS[43] = 90

    #expect(
      coordinator.animationSupportsIntermediateFrames(
        processIDs: [42],
        animationDuration: 0.18,
        refreshRateHz: 120
      ))
    #expect(
      coordinator.animationSupportsIntermediateFrames(
        processIDs: [43],
        animationDuration: 0.18,
        refreshRateHz: 120
      ) == false)
  }

  @Test
  func `Vertical reentry ignores cross-axis drift and leaving windows`() {
    let candidateStart = CGPoint(x: 8, y: 20)
    let candidateTarget = Rect(x: 10, y: -880, width: 800, height: 700)

    #expect(
      reentryTransitionDelta(
        reentryStart: CGPoint(x: 1_600, y: 20),
        reentryTarget: Rect(x: 10, y: 20, width: 800, height: 700),
        candidateStart: candidateStart,
        candidateTarget: candidateTarget
      ) == CGPoint(x: 0, y: -900))
    #expect(
      reentryTransitionDelta(
        reentryStart: candidateStart,
        reentryTarget: candidateTarget,
        candidateStart: candidateStart,
        candidateTarget: candidateTarget
      ) == nil)
  }

  @Test
  func `Reverse retarget uses last completed position during observation lag`() {
    let staleObserved = Rect(x: 900, y: 40, width: 800, height: 700)
    let completed = CGPoint(x: 100, y: 40)

    #expect(
      frameApplicationReference(
        pendingCorrection: nil,
        settlingReference: staleObserved,
        completedPosition: completed,
        previousTarget: Rect(x: 100, y: 40, width: 800, height: 700),
        nativeReference: nil
      ) == Rect(x: 100, y: 40, width: 800, height: 700))
  }

  @Test
  func `Frame application reference does not read native frame when cached`() {
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

    #expect(nativeFrameWasRead == false)
  }

  @Test
  func `Deferred frame correction survives snapshot rebuild`() {
    let windowID = WindowID(rawValue: 42)
    let deferred = Rect(x: 900, y: 40, width: 800, height: 700)
    let fresh = Rect(x: 100, y: 40, width: 800, height: 700)

    #expect(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [:],
        debtWindowIDs: [windowID]
      )[windowID] == deferred)
    #expect(
      frameCorrectionsPreservingDebt(
        existing: [windowID: deferred],
        observed: [windowID: fresh],
        debtWindowIDs: [windowID]
      )[windowID] == fresh)
  }

  @Test
  func `Deferred parking keeps coordinator busy until invalidated`() {
    let coordinator = AXFrameCoordinator()
    coordinator.deferredParkingWriteGenerations[WindowID(rawValue: 42)] = 3

    #expect(coordinator.isBusy)
    #expect(coordinator.hasPendingDeferredParkingWrites)
    #expect(coordinator.isBusy(for: WindowID(rawValue: 42)))
    #expect(coordinator.isBusy(for: WindowID(rawValue: 43)) == false)

    coordinator.invalidate(reason: "mouse-gesture")

    #expect(coordinator.isBusy == false)
    #expect(coordinator.hasPendingDeferredParkingWrites == false)
  }

  @Test
  func `Static settlement samples can exit the slow lane`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS[42] = 12
    coordinator.latencySensitiveProcessIDs.insert(42)

    coordinator.recordProcessLatencySamples([42: 0])

    #expect(coordinator.latencySensitiveProcessIDs.contains(42) == false)
  }

  @Test
  func `Exited processes are removed from slow lane diagnostics`() {
    let coordinator = AXFrameCoordinator()
    coordinator.predictedProcessLatencyMS = [42: 20, 43: 18]
    coordinator.latencySensitiveProcessIDs = [42, 43]

    coordinator.pruneProcessLatencyState(liveProcessIDs: [43])

    #expect(coordinator.slowProcessLatenciesMS == [43: 18])
  }

  @Test
  func `Stale batch does not record latency sample`() {
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

    #expect(accumulator.result.processLatencySamplesMS.isEmpty)
  }

  @Test
  func `Cursor warp requires successful target frame write`() {
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

    #expect(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: failed
      ) == nil)
    #expect(
      cursorWarpTimestampAfterFrameCompletion(
        requestedTimestamp: 10,
        targetWindowID: target,
        completion: succeeded
      ) == 10)
  }

  @Test
  func `Cursor warp allows observed convergence after failed write`() {
    let target = Rect(x: 100, y: 40, width: 800, height: 700)

    #expect(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: Rect(x: 900, y: 40, width: 800, height: 700),
        targetFrame: target
      ) == false)
    #expect(
      cursorWarpFrameReadiness(
        latestWriteSucceeded: false,
        observedFrame: target,
        targetFrame: target
      ))
  }

  @Test
  func `Synchronous size failure blocks warp readiness`() {
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ) == false)
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: true,
        asynchronousWriteSucceeded: false
      ) == false)
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: true
      ))
    #expect(
      frameSizeWriteSucceeded(
        sizeChanged: false,
        synchronousWriteSucceeded: false,
        animatesSize: false,
        asynchronousWriteSucceeded: false
      ))
  }

  @Test
  func `Asynchronous layout routes non animated size writes to coordinator`() {
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: false,
        animatesSize: false
      ))
    #expect(
      asynchronousSizeWriteIsRequired(
        sizeChanged: true,
        synchronousWriteSucceeded: true,
        animatesSize: false
      ) == false)
  }

  @Test
  func `Deferred frame focus rejects newer input before submission`() {
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 10
      ))
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: 10,
        latestUserInputTimestamp: 11
      ) == false)
    #expect(
      deferredFocusInputIsCurrent(
        requestedTimestamp: nil,
        latestUserInputTimestamp: 11
      ))
  }

  @Test
  func `Deferred frame focus waits for pending frame debt`() {
    let target = WindowID(rawValue: 42)

    #expect(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target]
      ) == false)
    #expect(
      deferredFocusFrameIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: []
      ))
  }

  @Test
  func `Deferred frame focus requires target write or observed convergence`() {
    let target = WindowID(rawValue: 42)
    let frame = Rect(x: 10, y: 20, width: 300, height: 400)

    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: nil,
        targetFrame: frame
      ) == false)
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [target],
        observedFrame: nil,
        targetFrame: frame
      ))
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [],
        successfulWindowIDs: [],
        observedFrame: frame,
        targetFrame: frame
      ))
    #expect(
      deferredFocusFrameCommitIsReady(
        targetWindowID: target,
        pendingFrameWindowIDs: [target],
        successfulWindowIDs: [target],
        observedFrame: frame,
        targetFrame: frame
      ) == false)
  }

  @Test
  func `Displaced queued frame completes as superseded`() async {
    await confirmation { confirm in
      let frame = QueuedPositionFrame(
        generation: 1,
        source: "test",
        writes: [:],
        animatedWindowIDs: [],
        animationDuration: 0,
        refreshRateHz: 60,
        displayIDs: [],
        initialProgressVelocity: 0,
        stagesVisibleBeforeParking: false
      ) { result in
        #expect(result.completedLatest == false)
        #expect(result.successfulWindowIDs.isEmpty)
        confirm()
      }

      completeSupersededFrame(frame)
    }
  }

  @Test
  func `Successful write reports the window that was written`() {
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
      displayIDs: [],
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

    #expect(reportedWindowIDs.withLock { $0 } == [firstWindowID, secondWindowID])
  }

  @Test
  func `Replacement frame preserves superseded async size write`() {
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

    #expect(result[carriedWindowID]?.size.width == 900)
    #expect(result[replacementWindowID]?.size.width == 1_000)
  }

  @Test
  func `Position only replacement retargets async size debt to latest plan`() {
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

    #expect(result[windowID]?.point == CGPoint(x: 100, y: 40))
    #expect(result[windowID]?.size == CGSize(width: 800, height: 600))
    #expect(result[windowID]?.positionChanged == true)
    #expect(result[windowID]?.sizeChanged == true)
    #expect(result[windowID]?.synchronousSizeWriteSucceeded != true)
  }

  @Test
  func `Recent internal write matches every recorded component`() {
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

    #expect(
      frameMatchesRecentInternalWrite(
        actual: sizeWrite.frame,
        write: sizeWrite
      ))
    #expect(
      frameMatchesRecentInternalWrite(
        actual: positionWrite.frame,
        write: positionWrite
      ))
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 900, height: 700),
        write: sizeWrite
      ) == false)
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 100, y: 40, width: 1_200, height: 800),
        write: positionWrite
      ) == false)
    #expect(
      frameMatchesRecentInternalWrite(
        actual: Rect(x: 400, y: 200, width: 1_200, height: 800),
        write: sizeWrite
      ) == false)
  }

  @Test
  func `Recent internal write history retains every live target`() {
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

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: first,
        now: 10.2
      ))
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: second,
        now: 10.2
      ))
  }

  @Test
  func `Invalidation retains recent internal write history`() {
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

    #expect(coordinator.activeWrites.isEmpty)
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: frame,
        now: 10.1
      ))
  }

  @Test
  func `Pruning recent internal writes drops closed windows`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    coordinator.recordInternalFrameWrite(
      Rect(x: 100, y: 40, width: 900, height: 700),
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )

    coordinator.pruneRecentInternalFrameWrites(liveWindowIDs: [], now: 10.2)

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 10.1
      ) == false)
  }

  @Test
  func `Pruning recent internal writes drops expired entries for live windows`() {
    let coordinator = AXFrameCoordinator()
    let windowID = WindowID(rawValue: 42)
    coordinator.recordInternalFrameWrite(
      Rect(x: 100, y: 40, width: 900, height: 700),
      windowID: windowID,
      positionChanged: true,
      sizeChanged: true,
      now: 10
    )

    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 12.6
      ) == false)
    #expect(
      coordinator.frameMatchesRecentInternalWrite(
        windowID: windowID,
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        now: 12.4
      ))
  }

  @Test
  func `Successful frame write intent keeps partial position write`() {
    #expect(
      successfulFrameWriteIntent(
        positionChanged: true,
        positionApplied: true,
        sizeChanged: true,
        sizeApplied: false
      ) == FrameWriteIntent(position: true, size: false))
  }

  @Test
  func `Live border window requires accepted frame readback after position write`() {
    let liveWindowID = WindowID(rawValue: 42)

    #expect(
      acceptedFrameRequiresReadback(
        windowID: liveWindowID,
        sizeChanged: false,
        liveBorderWindowID: liveWindowID
      ))
    #expect(
      acceptedFrameRequiresReadback(
        windowID: WindowID(rawValue: 43),
        sizeChanged: false,
        liveBorderWindowID: liveWindowID
      ) == false)
  }

  @Test
  func `Completed active size write is not carried into replacement`() {
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

    #expect(coordinator.activeWrites[windowID] == nil)
  }

  @Test
  func `Initial window commit uses short quarantine for fast retries`() {
    #expect(
      frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: true
      ).isApproximatelyEqual(to: 0.18, absoluteTolerance: 0.000_1)
    )
    #expect(
      frameCommitQuarantineDuration(
        animationDuration: 0,
        initialFrameSettlement: false
      ).isApproximatelyEqual(to: 0.8, absoluteTolerance: 0.000_1)
    )
  }

  @Test
  func `Initial window commit still covers animation`() {
    #expect(
      frameCommitQuarantineDuration(
        animationDuration: 0.35,
        initialFrameSettlement: true
      ).isApproximatelyEqual(to: 0.47, absoluteTolerance: 0.000_1)
    )
  }

  @Test
  func `Initial settlement repairs position or size drift`() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(initialFrameNeedsRepair(actual: target, target: target) == false)
    #expect(
      initialFrameNeedsRepair(
        actual: Rect(x: 140, y: 40, width: 1_200, height: 900),
        target: target
      ))
    #expect(
      initialFrameNeedsRepair(
        actual: Rect(x: 100, y: 40, width: 900, height: 700),
        target: target
      ))
  }

  @Test
  func `Initial settlement stays armed after matching frame`() {
    let target = Rect(x: 100, y: 40, width: 1_200, height: 900)

    #expect(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 10,
        deadline: 12.5
      ) == .stable)
    #expect(
      initialSettlementObservation(
        actual: target,
        target: target,
        now: 12.5,
        deadline: 12.5
      ) == .expired)
  }

  @Test
  func `Initial settlement repairs only stable drift`() {
    let generation: UInt64 = 4
    let first = InitialSettlementDriftSample(
      generation: generation,
      frame: Rect(x: 100, y: 40, width: 900, height: 700),
      observedAt: 10
    )

    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 100, y: 40, width: 1_000, height: 760),
        now: 10.1
      ) == false)
    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: first.frame,
        now: 10.04
      ) == false)
    #expect(
      initialSettlementDriftIsStable(
        previous: first,
        generation: generation,
        actual: Rect(x: 101, y: 40, width: 900, height: 700),
        now: 10.08
      ))
  }

  @Test
  func `Unchanged settlement drift preserves first observation time`() {
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

    #expect(unchanged.observedAt == 10)
    #expect(changed.observedAt == 10.04)
  }

  @Test
  func `Initial settlement schedules stable follow up before expiration`() {
    #expect(
      initialSettlementFollowUpDelay(now: 12.1, deadline: 12.5)!
        .isApproximatelyEqual(to: 0.06, absoluteTolerance: 0.000_1)
    )
    #expect(initialSettlementFollowUpDelay(now: 12.48, deadline: 12.5) == nil)
    #expect(initialSettlementFollowUpDelay(now: 12.5, deadline: 12.5) == nil)
  }

  @Test
  func `Initial settlement repair requires current generation and idle mouse`() {
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      ))
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 5,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: true,
        leftMouseButtonDown: false,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: true,
        animationRunning: false
      ) == false)
    #expect(
      initialSettlementRepairIsCurrent(
        expectedGeneration: 4,
        currentGeneration: 4,
        repairsSuspended: false,
        leftMouseButtonDown: false,
        animationRunning: true
      ) == false)
  }

  @Test
  func `Window events use incremental refresh only with stable PID context`() {
    let processIDs: Set<pid_t> = [101, 202]

    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      ) == processIDs)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: false,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: processIDs
      ) == nil)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: true,
        processIDs: processIDs
      ) == nil)
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: []
      ) == nil)
  }

  @Test
  func `Incremental refresh includes coalesced frame process`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedProcessIDs: [202]
      ) == [101, 202])
  }

  @Test
  func `Coalesced frame process during gesture does not require topology event`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true
      ) == [202])
  }

  @Test
  func `Coalesced frame process outside gesture uses full refresh`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202]
      ) == nil)
  }

  @Test
  func `Focus only synchronization reuses cached windows`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        allowsCachedRefresh: true
      ) == [])
  }

  @Test
  func `Frame notification refreshes only affected process`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: false,
        requiresFullSnapshot: false,
        processIDs: [],
        coalescedProcessIDs: [202],
        allowsCoalescedProcessRefresh: true,
        allowsCachedRefresh: true
      ) == [202])
  }

  @Test
  func `Coalesced mouse resize forces full refresh`() {
    #expect(
      incrementalWindowRefreshProcessIDs(
        hasCompletedSnapshot: true,
        eventPending: true,
        requiresFullSnapshot: false,
        processIDs: [101],
        coalescedEventRequiresFullSnapshot: true
      ) == nil)
  }

  @Test
  func `Workspace switch places visible windows before parking old workspace`() {
    let visible = WindowID(rawValue: 1)
    let parked = Set([WindowID(rawValue: 2), WindowID(rawValue: 3)])
    let all = parked.union([visible])

    #expect(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: true
      ) == [Set([visible]), parked])
    #expect(
      positionWritePhases(
        windowIDs: all,
        parkedWindowIDs: parked,
        stagesVisibleBeforeParking: false
      ) == [all])
  }

  @Test
  func `Only incoming workspace writes suppress native position animation`() {
    #expect(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: false,
        isIntermediate: false
      ))
    #expect(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: true,
        isIntermediate: false
      ) == false)
    #expect(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: false,
        isParked: false,
        isIntermediate: false
      ) == false)
    #expect(
      suppressesNativePositionAnimation(
        stagesVisibleBeforeParking: true,
        isParked: false,
        isIntermediate: true
      ) == false)
  }

  @Test
  func `Final workspace writes defer enhanced UI restoration`() {
    #expect(
      defersEnhancedUIRestore(
        stagesVisibleBeforeParking: true,
        isIntermediate: false,
        enhancedUIWasEnabled: true,
        positionChanged: true
      ))
    #expect(
      defersEnhancedUIRestore(
        stagesVisibleBeforeParking: true,
        isIntermediate: true,
        enhancedUIWasEnabled: true,
        positionChanged: true
      ) == false)
    #expect(
      defersEnhancedUIRestore(
        stagesVisibleBeforeParking: false,
        isIntermediate: false,
        enhancedUIWasEnabled: true,
        positionChanged: true
      ) == false)
  }

  @Test
  func `Deferred focus only applies to current selection`() {
    let target = WindowID(rawValue: 1)

    #expect(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: target
      ))
    #expect(
      shouldApplyDeferredFocus(
        targetWindowID: target,
        selectedWindowID: WindowID(rawValue: 2)
      ) == false)
  }

  @Test
  func `Expected horizontal commit lag is quarantined`() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ))
  }

  @Test
  func `Late intermediate rollback remains quarantined after target was observed`() {
    var observedExpectation = expectation
    observedExpectation.observedAt = 10.2

    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 260, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: observedExpectation,
        now: 10.5,
        leftMouseButtonDown: false
      ))
  }

  @Test
  func `Expired or external movement is not quarantined`() {
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.7,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 1_400, y: 180, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: false
      ) == false)
    #expect(
      frameIsOnExpectedCommitPath(
        actual: Rect(x: 420, y: 40, width: 800, height: 700),
        currentTarget: expectation.target,
        expectation: expectation,
        now: 10.4,
        leftMouseButtonDown: true
      ) == false)
  }

  @Test
  func `One pixel strip anchors require verified offscreen writes`() {
    let monitor = Rect(x: 0, y: 0, width: 1_512, height: 900)

    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ))
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -1_203, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ))
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: -905, y: 40, width: 1_204, height: 860),
        monitorFrames: [monitor]
      ) == false)
  }

  @Test
  func `Neighboring monitor prevents false sliver classification`() {
    #expect(
      requiresVerifiedOffscreenWrite(
        frame: Rect(x: 1_511, y: 40, width: 1_204, height: 860),
        monitorFrames: [
          Rect(x: 0, y: 0, width: 1_512, height: 900),
          Rect(x: 1_512, y: 0, width: 1_920, height: 1_080),
        ]
      ) == false)
  }

  @Test
  func `AX latency classification uses hysteresis`() {
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 11.9
      ) == false)
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: false,
        predictedLatencyMS: 12
      ))
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 7
      ))
    #expect(
      axProcessIsLatencySensitive(
        previouslySensitive: true,
        predictedLatencyMS: 6.9
      ) == false)
  }

  @Test
  func `Slow lane entry requires consecutive samples`() {
    var streak = ProcessLatencyStreak()
    #expect(processLatencyEntryIsConfirmed(sampleMS: 120, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 15, streak: &streak))
  }

  @Test
  func `Slow lane entry ignores single spike`() {
    var streak = ProcessLatencyStreak()
    #expect(processLatencyEntryIsConfirmed(sampleMS: 90, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 25, streak: &streak))
    #expect(processLatencyEntryIsConfirmed(sampleMS: 4, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 20, streak: &streak) == false)
    #expect(processLatencyEntryIsConfirmed(sampleMS: 30, streak: &streak))
  }

  @Test
  func `Animation lanes keep fast processes interpolated`() {
    let fast = WindowID(rawValue: 1)
    let slow = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slow],
        processIDs: [fast: 101, slow: 202],
        reenteringWindowIDs: [],
        finalOnlyProcessIDs: [202],
        horizontallyMovingResizeWindowIDs: []
      )
        == FrameAnimationLanePlan(
          interpolatedWindowIDs: [fast],
          finalOnlyWindowIDs: [slow],
          stagedFinalOnlyReentryWindowIDs: [],
          deferredSizeWindowIDs: []
        ))
  }

  @Test
  func `Horizontally moving resize animates before its final size commit`() {
    let resizing = WindowID(rawValue: 1)
    let translating = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [resizing, translating],
        processIDs: [resizing: 101, translating: 202],
        reenteringWindowIDs: [],
        finalOnlyProcessIDs: [],
        horizontallyMovingResizeWindowIDs: [resizing]
      )
        == FrameAnimationLanePlan(
          interpolatedWindowIDs: [resizing, translating],
          finalOnlyWindowIDs: [],
          stagedFinalOnlyReentryWindowIDs: [],
          deferredSizeWindowIDs: [resizing]
        ))
  }

  @Test
  func `Final only reentry keeps verified staging write`() {
    let fast = WindowID(rawValue: 1)
    let slowReentry = WindowID(rawValue: 2)

    #expect(
      frameAnimationLanePlan(
        animatedWindowIDs: [fast, slowReentry],
        processIDs: [fast: 101, slowReentry: 202],
        reenteringWindowIDs: [slowReentry],
        finalOnlyProcessIDs: [202],
        horizontallyMovingResizeWindowIDs: []
      ).stagedFinalOnlyReentryWindowIDs == [slowReentry])
  }

  @Test
  func `Skipped window keeps previous target until settlement`() {
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

    #expect(next[skipped] == previous[skipped])
    #expect(next[fast] == Rect(x: 20, y: 0, width: 400, height: 700))
  }

  @Test
  func `Skipped window keeps previous parking state until settlement`() {
    let skipped = WindowID(rawValue: 1)
    let fast = WindowID(rawValue: 2)

    #expect(
      hiddenWindowsPreservingSkippedWindows(
        previous: [skipped],
        desired: [fast],
        skippedWindowIDs: [skipped]
      ) == [skipped, fast])
  }

  @Test
  func `Ribbon navigation never plans size writes`() {
    #expect(
      frameWriteIntent(
        reference: Rect(x: 800, y: 0, width: 600, height: 700),
        target: Rect(x: 100, y: 0, width: 1_000, height: 900),
        positionsOnly: true
      ) == FrameWriteIntent(position: true, size: false))
  }

  @Test
  func `Frame animation interpolates position and size`() {
    #expect(
      interpolatedFrame(
        from: Rect(x: 100, y: 40, width: 600, height: 700),
        to: Rect(x: 40, y: 20, width: 1_000, height: 800),
        progress: 0.25
      ) == Rect(x: 85, y: 35, width: 700, height: 725))
  }

  @Test
  func `Matching vertical reentry start skips staging`() {
    #expect(
      reentryStartRequiresStaging(
        observed: CGPoint(x: 4, y: 899),
        planned: CGPoint(x: 4, y: 899)
      ) == false
    )
    #expect(
      reentryStartRequiresStaging(
        observed: CGPoint(x: 1_511, y: 37),
        planned: CGPoint(x: 4, y: 899)
      )
    )
  }
}
