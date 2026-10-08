import ApplicationServices
import DefiModel
import DefiRuntime
import Synchronization
import Testing

@testable import DefiMacOS

@Suite(.serialized)
struct FrameGeometryReadTests {
  private let accepted = Rect(x: 120, y: 40, width: 650, height: 700)

  private func write(_ processID: pid_t, sizeChanged: Bool = true) -> AsyncPositionWrite {
    let element = AXUIElementCreateApplication(processID)
    return AsyncPositionWrite(
      element: element, application: element, processID: processID,
      fromPoint: .zero, point: CGPoint(x: 100, y: 40),
      fromSize: CGSize(width: 800, height: 700), size: CGSize(width: 900, height: 700),
      positionChanged: true, sizeChanged: sizeChanged, animatesSize: false,
      synchronousSizeWriteSucceeded: true, enhancedUIWasEnabled: false,
      timeoutSeconds: 0.016, isParked: false, isReentering: false,
      requiresVerifiedOffscreenWrite: false
    )
  }

  private func frame(_ writes: [WindowID: AsyncPositionWrite]) -> QueuedPositionFrame {
    QueuedPositionFrame(
      generation: 0, source: "geometry-test", writes: writes, animatedWindowIDs: [],
      animationDuration: 0, refreshRateHz: 120, displayIDs: [], initialProgressVelocity: 0,
      stagesVisibleBeforeParking: false, completion: nil
    )
  }

  private func bind(_ coordinator: AXFrameCoordinator, writes: [WindowID: AsyncPositionWrite])
    -> (SnapshotEngine, QueuedPositionFrame) {
    let engine = SnapshotEngine(frameCoordinator: coordinator, userInputTracker: UserInputTracker())
    engine.elements = writes.mapValues(\.element)
    engine.processIDs = writes.mapValues(\.processID)
    engine.applications = Dictionary(writes.values.map { ($0.processID, $0.application) },
      uniquingKeysWith: { first, _ in first })
    return (engine, boundFrame(engine, writes: writes))
  }

  private func boundFrame(_ engine: SnapshotEngine, writes: [WindowID: AsyncPositionWrite])
    -> QueuedPositionFrame {
    var bound = writes
    for target in engine.borderGeometryTargets(for: Set(writes.keys)) {
      bound[target.windowID]?.binding = target
    }
    return frame(bound)
  }

  @Test func acceptedReadsOverlapAcrossProcessesAndReturnClampedFrames() {
    let overlap = Mutex(false)
    let value = accepted
    let firstEntered = Mutex(false)
    let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
    let paired = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { _ in
        let isFirst = firstEntered.withLock { value in
          let wasFirst = !value
          value = true
          return wasFirst
        }
        if isFirst {
          first.signal()
          overlap.withLock { $0 = second.wait(timeout: .now() + 3) == .success }
        } else {
          #expect(first.wait(timeout: .now() + 3) == .success)
          second.signal()
        }
        return value
      }
    ))
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let (engine, request) = bind(paired, writes: [a: write(-41), b: write(-42)])
    let result = paired.readAcceptedFrames(for: request, successfulWindowIDs: [a, b])
    #expect(overlap.withLock { $0 })
    #expect(engine.consumeAcceptedFrames(result) == [a: accepted, b: accepted])
    #expect(paired.completedSize(for: a) == CGSize(width: 650, height: 700))
    #expect(paired.completedPosition(for: b) == CGPoint(x: 120, y: 40))
    #expect(paired.processWriteQueueReservations.isEmpty)
  }

  @Test func acceptedReadsSerializeSameProcessAndKeepEligibilityAndFailures() {
    let reads = Mutex(0)
    let value = accepted
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { _ in
        let index = reads.withLock { $0 += 1; return $0 }
        return index == 2 ? nil : value
      }
    ))
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let excluded = WindowID(rawValue: 3), failedWrite = WindowID(rawValue: 4)
    let (engine, request) = bind(coordinator, writes: [
      a: write(-41), b: write(-41), excluded: write(-41, sizeChanged: false), failedWrite: write(-41)])
    let result = coordinator.readAcceptedFrames(for: request, successfulWindowIDs: [a, b, excluded])
    #expect(engine.consumeAcceptedFrames(result) == [a: accepted])
    #expect(reads.withLock { $0 } == 2)
    #expect(coordinator.completedSize(for: a) == CGSize(width: 650, height: 700))
    #expect(coordinator.completedSize(for: b) == nil)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test func generationChangeDuringAcceptedReadCannotReconcileCompletedGeometry() {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0), result = Mutex<[BorderGeometryObservation]>([])
    let value = accepted
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { _ in
        entered.signal()
        #expect(resume.wait(timeout: .now() + 3) == .success)
        return value
      }
    ))
    let id = WindowID(rawValue: 1)
    let (engine, request) = bind(coordinator, writes: [id: write(-41)])
    DispatchQueue.global().async {
      let frames = coordinator.readAcceptedFrames(for: request, successfulWindowIDs: [id])
      result.withLock { $0 = frames }
      done.signal()
    }
    #expect(entered.wait(timeout: .now() + 3) == .success)
    coordinator.invalidate(reason: "test-generation")
    resume.signal()
    #expect(done.wait(timeout: .now() + 3) == .success)
    #expect(engine.consumeAcceptedFrames(result.withLock { $0 }).isEmpty)
    #expect(coordinator.completedPosition(for: id) == nil)
    #expect(coordinator.latestBorderFrame(for: id) == nil)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  private func platform(_ coordinator: AXFrameCoordinator) -> MacOSPlatform {
    NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform(frameCoordinator: coordinator) }
    }
  }

  private func deliveredFrames(_ platform: MacOSPlatform,
    observations: [BorderGeometryObservation]) -> [WindowID: Rect] {
    let delivered = Mutex<[WindowID: Rect]>([:])
    NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated {
        platform.consumeAcceptedFrames(observations, handler: { frames in
          delivered.withLock { $0 = frames }
        })
      }
    }
    return delivered.withLock { $0 }
  }

  @Test(arguments: ["accepted-before-join", "queued-before-join", "delivered-after-join"])
  func finalJoinDoesNotOverwriteNewerFastProcessObservation(delivery: String) throws {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let old = accepted, newer = Rect(x: 240, y: 40, width: 720, height: 700)
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0), result = Mutex<[BorderGeometryObservation]>([])
    let aWrite = write(-41), bWrite = write(-42)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { element in
        if CFEqual(element, bWrite.element) {
          entered.signal()
          #expect(release.wait(timeout: .now() + 3) == .success)
        }
        return old
      }
    ))
    let platform = platform(coordinator), engine = platform.snapshotEngine
    engine.elements = [a: aWrite.element, b: bWrite.element]
    engine.processIDs = [a: -41, b: -42]
    engine.applications = [-41: aWrite.application, -42: bWrite.application]
    coordinator.borderNativeFrameReader = { _ in newer }
    let request = boundFrame(engine, writes: [a: aWrite, b: bWrite])
    DispatchQueue.global().async {
      let observations = coordinator.readAcceptedFrames(for: request, successfulWindowIDs: [a, b])
      result.withLock { $0 = observations }
      done.signal()
    }
    #expect(entered.wait(timeout: .now() + 3) == .success)
    let lane = coordinator.reserveProcessWriteQueue(for: -41)
    lane.queue.sync {}
    lane.release()
    let target = try #require(engine.borderGeometryTargets(for: [a]).first)
    let observation = BorderGeometryObservation(ticket: BorderGeometryReadTicket(target: target,
      generation: 0), sampledAt: ProcessInfo.processInfo.systemUptime, frame: newer)
    let held = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
    if delivery == "accepted-before-join" {
      #expect(engine.acceptBorderObservation(observation))
    } else if delivery == "queued-before-join" {
      coordinator.borderObservationScheduler = { callback in held.withLock { $0 = callback } }
      coordinator.borderObservationHandler = { observations in
        for observation in observations { _ = engine.acceptBorderObservation(observation) }
      }
      coordinator.requestBorderGeometry([target])
      coordinator.borderGeometryReadGroup.wait()
      #expect(deliveredFrames(platform, observations: result.withLock { $0 }).isEmpty)
    }
    #expect(done.wait(timeout: .now()) == .timedOut)
    release.signal()
    #expect(done.wait(timeout: .now() + 3) == .success)
    if delivery == "delivered-after-join" {
      #expect(coordinator.completedSize(for: a) == CGSize(width: 650, height: 700))
      #expect(engine.acceptBorderObservation(observation))
    } else if delivery == "queued-before-join" {
      #expect(deliveredFrames(platform, observations: result.withLock { $0 }) == [b: old])
      #expect(coordinator.completedSize(for: a) == nil)
      let callback = try #require(held.withLock { $0 })
      DispatchQueue.main.sync { MainActor.assumeIsolated { callback() } }
    }
    engine.recordCachedBorderFrame(for: a)
    #expect(deliveredFrames(platform, observations: result.withLock { $0 }) == [b: old])
    #expect(coordinator.latestBorderFrame(for: a) == newer)
    #expect(engine.latestObservedFrames[a] == newer)
    #expect(coordinator.completedSize(for: b) == CGSize(width: 650, height: 700))
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  private func invalidate(_ engine: SnapshotEngine, id: WindowID, cause: String) {
    let elements = engine.elements, applications = engine.applications, pids = engine.processIDs
    switch cause {
    case "remove": engine.elements[id] = nil
    case "rebind": engine.elements[id] = AXUIElementCreateApplication(-99)
    case "id-reuse":
      engine.elements[id] = nil
      engine.elements = elements
    case "pid-reuse":
      engine.applications = [:]
      engine.applications = applications
    case "reset":
      engine.invalidateAccessibilitySession()
      _ = engine.consumeObservations()
      engine.applications = applications
    case "termination", "destroyed":
      engine.recordObservation(cause == "termination" ? .applicationTerminated : .windows,
        processID: pids[id], windowID: cause == "destroyed" ? id : nil)
      engine.elements = elements
    default: Issue.record("Unknown invalidation")
    }
    engine.latestObservedFrames = [:]
  }

  @Test(arguments: ["read", "join", "delivery"],
    ["remove", "rebind", "id-reuse", "pid-reuse", "reset", "termination", "destroyed"])
  func lifecycleRejectsFinalSamplesAndDelayedHandler(stage: String, cause: String) {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2), old = accepted
    let aEntered = DispatchSemaphore(value: 0), aRelease = DispatchSemaphore(value: 0)
    let bEntered = DispatchSemaphore(value: 0), bRelease = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0), result = Mutex<[BorderGeometryObservation]>([])
    let aWrite = write(-41), bWrite = write(-42)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { element in
        if CFEqual(element, bWrite.element) {
          bEntered.signal()
          #expect(bRelease.wait(timeout: .now() + 3) == .success)
        } else if stage == "read" {
          aEntered.signal()
          #expect(aRelease.wait(timeout: .now() + 3) == .success)
        }
        return old
      }
    ))
    let platform = platform(coordinator), engine = platform.snapshotEngine
    engine.elements = [a: aWrite.element, b: bWrite.element]
    engine.processIDs = [a: -41, b: -42]
    engine.applications = [-41: aWrite.application, -42: bWrite.application]
    let request = boundFrame(engine, writes: [a: aWrite, b: bWrite])
    DispatchQueue.global().async {
      let observations = coordinator.readAcceptedFrames(for: request, successfulWindowIDs: [a, b])
      result.withLock { $0 = observations }
      done.signal()
    }
    #expect(bEntered.wait(timeout: .now() + 3) == .success)
    if stage == "read" {
      #expect(aEntered.wait(timeout: .now() + 3) == .success)
    } else {
      let lane = coordinator.reserveProcessWriteQueue(for: -41)
      lane.queue.sync {}
      lane.release()
    }
    if stage != "delivery" { invalidate(engine, id: a, cause: cause) }
    aRelease.signal()
    bRelease.signal()
    #expect(done.wait(timeout: .now() + 3) == .success)
    if stage == "delivery" {
      #expect(engine.latestObservedFrames[a] == old)
      invalidate(engine, id: a, cause: cause)
    }
    let delivered = deliveredFrames(platform, observations: result.withLock { $0 })
    #expect(delivered[a] == nil)
    if cause != "reset" && cause != "pid-reuse" {
      #expect(delivered[b] == old)
      #expect(coordinator.completedSize(for: b) == CGSize(width: 650, height: 700))
    }
    #expect(coordinator.latestBorderFrame(for: a) == nil)
    #expect(coordinator.completedSize(for: a) == nil)
    #expect(coordinator.completedPosition(for: a) == nil)
    #expect(engine.latestObservedFrames[a] == nil)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test func oldWriteBindingCannotAdoptReplacementRevisionBeforeRead() {
    let id = WindowID(rawValue: 1), old = accepted, reads = Mutex(0)
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { _ in reads.withLock { $0 += 1 }; return old }
    ))
    let (engine, request) = bind(coordinator, writes: [id: write(-41)])
    invalidate(engine, id: id, cause: "id-reuse")
    #expect(coordinator.readAcceptedFrames(for: request, successfulWindowIDs: [id]).isEmpty)
    #expect(reads.withLock { $0 } == 0)
    let current = boundFrame(engine, writes: request.writes)
    #expect(engine.consumeAcceptedFrames(coordinator.readAcceptedFrames(for: current,
      successfulWindowIDs: [id])) == [id: old])
    #expect(reads.withLock { $0 } == 1)
    #expect(coordinator.completedSize(for: id) == CGSize(width: 650, height: 700))
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test func newerWriteOrGenerationRejectsDelayedFinalAcceptance() {
    let id = WindowID(rawValue: 1), old = accepted
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(frameReader: { _ in old }))
    let platform = platform(coordinator), engine = platform.snapshotEngine, write = write(-41)
    engine.elements = [id: write.element]
    engine.processIDs = [id: -41]
    engine.applications = [-41: write.application]
    let observations = coordinator.readAcceptedFrames(for: boundFrame(engine, writes: [id: write]),
      successfulWindowIDs: [id])
    #expect(deliveredFrames(platform, observations: observations) == [id: old])
    coordinator.recordCompletedPosition(CGPoint(x: 300, y: 40), windowID: id)
    engine.recordCachedBorderFrame(for: id)
    #expect(deliveredFrames(platform, observations: observations).isEmpty)
    #expect(engine.latestObservedFrames[id] == Rect(x: 300, y: 40, width: 650, height: 700))
    coordinator.invalidate(reason: "newer-intent")
    #expect(deliveredFrames(platform, observations: observations).isEmpty)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test func pairedFrameDecoderRejectsMalformedAndInvalidValues() throws {
    var point = CGPoint(x: 120, y: 40), size = CGSize(width: 650, height: 700)
    let position = try #require(AXValueCreate(.cgPoint, &point))
    let extent = try #require(AXValueCreate(.cgSize, &size))
    #expect(decodeWindowFrame([position, extent]) == accepted)
    for values: [AnyObject] in [[], [position], [position, extent, extent],
      [extent, position], [kCFNull, extent], ["invalid" as NSString, extent]] {
      #expect(decodeWindowFrame(values) == nil)
    }
    var error = AXError.cannotComplete
    let failure = try #require(AXValueCreate(.axError, &error))
    #expect(decodeWindowFrame([position, failure]) == nil)
    for badSize in [CGSize(width: 0, height: 700), CGSize(width: -1, height: 700),
      CGSize(width: CGFloat.infinity, height: 700)] {
      var badSize = badSize
      #expect(decodeWindowFrame([position, try #require(AXValueCreate(.cgSize, &badSize))]) == nil)
    }
    point.x = .nan
    #expect(decodeWindowFrame([try #require(AXValueCreate(.cgPoint, &point)), extent]) == nil)
  }

  @Test func unsupportedBatchFallsBackButFailedOrPartialBatchDoesNotInventGeometry() throws {
    var point = CGPoint(x: 120, y: 40), size = CGSize(width: 650, height: 700)
    let position = try #require(AXValueCreate(.cgPoint, &point))
    let extent = try #require(AXValueCreate(.cgSize, &size))
    let element = AXUIElementCreateApplication(-41)
    var attributes: [String] = []
    let fallback = copyWindowFrame(element, multipleReader: { _ in (.notImplemented, nil) },
      attributeReader: { _, attribute in
        attributes.append(attribute as String)
        return CFEqual(attribute, kAXPositionAttribute as CFString) ? position : extent
      })
    #expect(fallback == accepted)
    #expect(attributes == [kAXPositionAttribute, kAXSizeAttribute])
    for error in [AXError.cannotComplete, .failure] {
      #expect(copyWindowFrame(element, multipleReader: { _ in (error, nil) },
        attributeReader: { _, _ in Issue.record("Unexpected fallback"); return position }) == nil)
    }
    #expect(copyWindowFrame(element, multipleReader: { _ in (.success, [position]) }) == nil)
    #expect(copyWindowFrame(element, multipleReader: { _ in (.attributeUnsupported, nil) },
      attributeReader: { _, _ in nil }) == nil)
  }

  @Test func explicitFrameReaderOverridesPositionInjectionAndDefaultPreservesIt() {
    let calls = Mutex(0), element = AXUIElementCreateApplication(-41)
    let value = accepted
    let injected = AXFrameAccessibilityWriter(positionReader: { _ in
      calls.withLock { $0 += 1 }; return CGPoint(x: 5, y: 6)
    }, frameReader: { _ in value })
    #expect(injected.readFrame(element) == accepted)
    #expect(calls.withLock { $0 } == 0)
    let sequential = AXFrameAccessibilityWriter(positionReader: { _ in
      calls.withLock { $0 += 1 }; return CGPoint(x: 5, y: 6)
    })
    #expect(sequential.readFrame(element) == nil)
    #expect(calls.withLock { $0 } == 1)
    #expect(sequential.readPosition(element) == CGPoint(x: 5, y: 6))
  }
}
