import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Synchronization
import Testing
@testable import DefiMacOS

struct FrameSettlementVerificationTests {
  private let target = Rect(x: 2, y: 37, width: 752, height: 902)
  private let rollback = Rect(x: 25, y: 37, width: 752, height: 902)

  private nonisolated func accessibilityWriter(reads: DiscoveryReadFixture) -> AXFrameAccessibilityWriter {
    AXFrameAccessibilityWriter(
      positionWriter: { @Sendable write, point in
        reads.state.withLock { state in
          let hash = CFHash(write.element)
          guard var window = state.windowsByHash[hash] else { return false }
          window.frame.x = point.x
          window.frame.y = point.y
          state.windowsByHash[hash] = window
          return true
        }
      },
      sizeWriter: { @Sendable write, size in
        reads.state.withLock { state in
          let hash = CFHash(write.element)
          guard var window = state.windowsByHash[hash] else { return false }
          window.frame.width = size.width
          window.frame.height = size.height
          state.windowsByHash[hash] = window
          return true
        }
      },
      sizeReader: { @Sendable element in
        reads.state.withLock { state in
          state.windowsByHash[CFHash(element)].map { CGSize(width: $0.frame.width, height: $0.frame.height) }
        }
      },
      positionReader: { @Sendable element in
        reads.state.withLock { state in
          state.windowsByHash[CFHash(element)].map { CGPoint(x: $0.frame.x, y: $0.frame.y) }
        }
      },
      frameReader: { @Sendable element in reads.state.withLock { $0.windowsByHash[CFHash(element)]?.frame } },
      enhancedUIWriter: { @Sendable _, _ in true },
      nativePositionReader: { @Sendable _, _ in nil }
    )
  }

  @MainActor private func fixture() async -> (MacOSPlatform, DiscoveryReadFixture, WindowID, Double) {
    let reads = DiscoveryReadFixture()
    reads.revealsNewWindow = false
    reads.failsProcess = nil
    let coordinator = AXFrameCoordinator(accessibilityWriter: accessibilityWriter(reads: reads))
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform(frameCoordinator: coordinator) }
    }
    let engine = platform.snapshotEngine
    let start = ProcessInfo.processInfo.systemUptime
    reads.state.withLock { $0.now = start }
    let id = WindowID(rawValue: 4101)
    var windows: [Window] = []
    for index in 1...3 {
      let pid: pid_t = index == 3 ? 42 : 41
      let windowID = WindowID(rawValue: 4100 + UInt64(index))
      let element = AXUIElementCreateApplication(-61000 - Int32(index))
      let window = Window(id: windowID, appID: "measurement", title: "known-\(index)",
        frame: Rect(x: Double(index * 1000), y: 37, width: 752, height: 902),
        role: kAXWindowRole, subrole: kAXStandardWindowSubrole, processID: pid)
      windows.append(window)
      engine.elements[windowID] = element
      engine.processIDs[windowID] = pid
      reads.windowLists[pid, default: []].append(element)
      reads.windowsByHash[CFHash(element)] = window
    }
    engine.applications = [41: AXUIElementCreateApplication(-41), 42: AXUIElementCreateApplication(-42)]
    engine.applicationIDsByProcess = [41: "measurement", 42: "measurement"]
    engine.enhancedUIByProcess = [41: false, 42: false]
    engine.hasCompletedWindowSnapshot = true
    engine.overviewPresentationActive = true
    engine.lastApplicationWindowElements = reads.windowLists
    engine.lastSnapshotWindows = windows
    engine.latestObservedFrames = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.frame) })
    var access = reads.access()
    access.snapshotCGWindows = {
      reads.state.withLock { state in
        state.windowsByHash.values.map {
          CGWindowRecord(id: UInt32($0.id.rawValue), processID: $0.processID!, layer: 0,
            title: $0.title, frame: $0.frame, isOnscreen: true)
        }
      }
    }
    access.nativeFocus = { _ in nil }
    engine.discoveryMeasurementAccess = access
    engine.lastMonitorFrames = [Rect(x: 0, y: 0, width: 4000, height: 1200)]
    await apply(target, id: id, platform: platform)
    return (platform, reads, id, start)
  }

  private func setFrame(_ frame: Rect, id: WindowID, reads: DiscoveryReadFixture) {
    reads.state.withLock { state in
      for hash in state.windowsByHash.keys where state.windowsByHash[hash]?.id == id {
        state.windowsByHash[hash]?.frame = frame
      }
    }
  }

  @MainActor private func apply(_ frame: Rect, id: WindowID, platform: MacOSPlatform) async {
    platform.frameCoordinator.running = true
    await platform.apply([FrameAssignment(windowID: id, frame: frame)], positionsOnly: true, updateVisibility: false)
    platform.frameCoordinator.drain()
  }

  @MainActor @Test(arguments: [false, true])
  func silentRollbackIsReadAfterQuarantine(earlyMatch: Bool) async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    reads.state.withLock { $0.now = start + 0.2 }
    setFrame(earlyMatch ? target : rollback, id: id, reads: reads)
    engine.recordObservation(.frame, processID: 41, windowID: id)
    let early = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(early.windows.first { $0.id == id }?.frame == (earlyMatch ? target : rollback))
    #expect(early.targetMismatches.isEmpty)
    #expect(platform.nextFrameCommitVerificationAt == start + 0.8)
    setFrame(rollback, id: id, reads: reads)
    reads.state.withLock { $0.now = start + 0.9 }
    #expect(platform.requestDueFrameCommitVerification(now: start + 0.9))
    #expect(!platform.requestDueFrameCommitVerification(now: start + 0.9))
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.freshFrameObservationIDs.contains(id))
    #expect(final.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
    #expect(engine.pendingFrameCorrections[id] == rollback)
    #expect(final.externallyChangedFrames.isEmpty)
    let cached = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(cached.windows.first { $0.id == id }?.frame == rollback)
    #expect(engine.pendingFrameCorrections[id] == rollback)
    #expect(engine.pendingFrameDebtWindowIDs.contains(id))
    await apply(target, id: id, platform: platform)
    reads.state.withLock { $0.now = start + 1.8 }
    let verified = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(verified.windows.first { $0.id == id }?.frame == Rect(x: 2, y: 37, width: 752, height: 902))
    #expect(verified.targetMismatches.isEmpty)
    #expect(engine.frameCommitExpectations[id] == nil)
    #expect(!engine.pendingFrameDebtWindowIDs.contains(id))
  }

  @MainActor @Test func widthChangeAndSilentSiblingRollbackConvergeTogether() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    let sibling = WindowID(rawValue: 4102)
    let resized = Rect(x: 2, y: 37, width: 600, height: 902)
    let siblingTarget = Rect(x: 618, y: 37, width: 752, height: 902)
    let siblingRollback = Rect(x: 641, y: 37, width: 752, height: 902)
    let assignments = [FrameAssignment(windowID: id, frame: resized),
      FrameAssignment(windowID: sibling, frame: siblingTarget)]
    reads.state.withLock { $0.now = start + 0.1 }
    platform.frameCoordinator.running = true
    await platform.apply(assignments, updateVisibility: false)
    platform.frameCoordinator.drain()
    #expect(reads.windowsByHash.values.first { $0.id == id }?.frame == resized)
    #expect(reads.windowsByHash.values.first { $0.id == sibling }?.frame == siblingTarget)
    setFrame(siblingRollback, id: sibling, reads: reads)
    reads.state.withLock { $0.now = start + 0.3 }
    engine.recordObservation(.frame, processID: 41, windowID: sibling)
    let early = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(early.windows.first { $0.id == sibling }?.frame == siblingRollback)
    #expect(early.targetMismatches.isEmpty)
    reads.state.withLock { $0.now = start + 1 }
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.windows.first { $0.id == id }?.frame == resized)
    #expect(final.targetMismatches == [FrameMismatch(windowID: sibling, actual: siblingRollback, target: siblingTarget)])
    #expect(engine.pendingFrameCorrections == [sibling: siblingRollback])
    #expect(engine.pendingFrameDebtWindowIDs == [sibling])
    platform.frameCoordinator.running = true
    await platform.apply(assignments, updateVisibility: false)
    platform.frameCoordinator.drain()
    reads.state.withLock { $0.now = start + 2 }
    let corrected = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(corrected.windows.first { $0.id == id }?.frame == resized)
    #expect(corrected.windows.first { $0.id == sibling }?.frame == siblingTarget)
    #expect(corrected.targetMismatches.isEmpty)
    #expect(engine.pendingFrameCorrections.isEmpty)
    #expect(engine.pendingFrameDebtWindowIDs.isEmpty)
    #expect(engine.frameCommitExpectations.isEmpty)
  }

  @MainActor @Test func alreadyCorrectFrameRetiresOnlyWithFreshFinalRead() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    reads.state.withLock { $0.now = start + 0.2 }
    engine.recordObservation(.frame, processID: 41, windowID: id)
    let early = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(early.windows.first { $0.id == id }?.frame == target)
    #expect(engine.frameCommitExpectations[id] != nil)
    reads.state.withLock { $0.now = start + 0.9 }
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.freshFrameObservationIDs == [id])
    #expect(final.windows.first { $0.id == id }?.frame == target)
    #expect(final.targetMismatches.isEmpty)
    #expect(engine.frameCommitExpectations[id] == nil)
  }

  @MainActor @Test func silentFinalMatchRecordsFirstObservationAndRetiresDebt() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    reads.state.withLock { $0.now = start + 0.9 }
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.windows.first { $0.id == id }?.frame == target)
    #expect(final.freshFrameObservationIDs == [id])
    #expect(engine.observedFrameCommitCount == 1)
    #expect(engine.frameCommitExpectations[id] == nil)
    #expect(!engine.pendingFrameDebtWindowIDs.contains(id))
  }

  @MainActor @Test func readStartingBeforeDeadlineCannotVerifyAfterDeadline() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    var access = reads.access()
    let original = access.windowAttributes
    access.snapshotCGWindows = engine.discoveryMeasurementAccess?.snapshotCGWindows
    access.nativeFocus = { _ in nil }
    access.windowAttributes = { element, pid in
      let result = original(element, pid)
      reads.state.withLock { $0.now = start + 0.9 }
      return result
    }
    engine.discoveryMeasurementAccess = access
    reads.state.withLock { $0.now = start + 0.7 }
    engine.recordObservation(.frame, processID: 41, windowID: id)
    let crossing = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(crossing.windows.first { $0.id == id }?.frame == target)
    #expect(engine.frameCommitExpectations[id] != nil)
    setFrame(rollback, id: id, reads: reads)
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
  }

  @MainActor @Test func failedReadsRetainObligationUntilWatchdogCanRepair() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    var failedAccess = engine.discoveryMeasurementAccess!
    failedAccess.windowAttributes = { _, _ in
      AXWindowAttributes(minimized: nil, frame: nil, title: "", role: nil, subrole: nil)
    }
    engine.discoveryMeasurementAccess = failedAccess
    for time in [0.9, 1.3, 1.8] {
      reads.state.withLock { $0.now = start + time }
      let failed = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
      #expect(failed.windows.first { $0.id == id }?.frame == Rect(x: 1000, y: 37, width: 752, height: 902))
      #expect(!failed.freshFrameObservationIDs.contains(id))
      #expect(engine.frameCommitExpectations[id] != nil)
    }
    #expect(platform.nextFrameCommitVerificationAt == nil)
    #expect(engine.frameCommitExpectations[id]?.verificationAttempts == 3)
    var restored = reads.access()
    restored.snapshotCGWindows = failedAccess.snapshotCGWindows
    restored.nativeFocus = { _ in nil }
    engine.discoveryMeasurementAccess = restored
    setFrame(rollback, id: id, reads: reads)
    reads.state.withLock { $0.now = start + 30 }
    let watchdog = engine.snapshot(config: Config(), forceFullWindowRefresh: true)
    #expect(watchdog.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
    await apply(target, id: id, platform: platform)
    reads.state.withLock { $0.now = start + 31 }
    let verified = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(verified.windows.first { $0.id == id }?.frame == target)
    #expect(engine.frameCommitExpectations[id] == nil)
  }

  @MainActor @Test func exhaustedVerificationDoesNotForceUnrelatedSnapshots() async throws {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    for time in [0.9, 1.3, 1.8] {
      #expect(engine.requestDueFrameCommitVerification(now: start + time))
      let read = try #require(engine.captureFrameCommitReads()[id])
      engine.finishFrameCommitReads([id: read], attemptedWindowIDs: [id], now: start + time)
    }
    #expect(engine.frameCommitExpectations[id]?.verificationAttempts == 3)
    #expect(platform.nextFrameCommitVerificationAt == nil)
    #expect(engine.retainedWindowIDs.isEmpty)
    setFrame(rollback, id: id, reads: reads)
    let calls = reads.state.withLock { $0.attributeCalls }
    reads.state.withLock { $0.now = start + 2.3 }
    let cached = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(cached.windows.first { $0.id == id }?.frame == Rect(x: 1000, y: 37, width: 752, height: 902))
    #expect(cached.freshFrameObservationIDs.isEmpty)
    #expect(reads.state.withLock { $0.attributeCalls } == calls)
    #expect(engine.frameCommitExpectations[id]?.verification == .watchdog)
    reads.state.withLock { $0.now = start + 30 }
    let watchdog = engine.snapshot(config: Config(), forceFullWindowRefresh: true)
    #expect(watchdog.windows.first { $0.id == id }?.frame == rollback)
    #expect(watchdog.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
    #expect(engine.pendingFrameCorrections[id] == rollback)
    #expect(engine.pendingFrameDebtWindowIDs.contains(id))
  }

  @MainActor @Test func deferredReadDoesNotSpendVerificationAttempts() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    setFrame(rollback, id: id, reads: reads)
    reads.state.withLock { $0.now = start + 0.9 }
    platform.frameCoordinator.lock.withLock { platform.frameCoordinator.activeAnimationRunning = true }
    let deferred = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(deferred.windows.first { $0.id == id }?.frame == Rect(x: 1000, y: 37, width: 752, height: 902))
    #expect(engine.frameCommitExpectations[id]?.verificationAttempts == 0)
    platform.frameCoordinator.lock.withLock { platform.frameCoordinator.activeAnimationRunning = false }
    reads.state.withLock { $0.now = start + 1.2 }
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
  }

  @MainActor @Test func anotherProcessCommitDoesNotCancelOrRefreshThisWindowsSibling() async {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    let other = WindowID(rawValue: 4103)
    let otherTarget = Rect(x: 3000, y: 37, width: 752, height: 902)
    engine.targetFrames[other] = otherTarget
    engine.registerFrameCommit(FrameCommitExpectation(commitID: 999, from: otherTarget,
      target: otherTarget, issuedAt: start + 0.1, deadline: start + 2, observedAt: nil), for: other)
    setFrame(rollback, id: id, reads: reads)
    reads.state.withLock { $0.now = start + 0.9 }
    let first = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(first.freshFrameObservationIDs == [id])
    #expect(first.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: target)])
    #expect(engine.frameCommitExpectations[other]?.target == otherTarget)
    #expect(first.windows.first { $0.id.rawValue == 4102 }?.frame == Rect(x: 2000, y: 37, width: 752, height: 902))
    reads.state.withLock { $0.now = start + 2.1 }
    let second = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(second.freshFrameObservationIDs == [other])
    #expect(second.windows.first { $0.id == other }?.frame == otherTarget)
    #expect(engine.frameCommitExpectations[other] == nil)
    #expect(engine.pendingFrameCorrections[id] == rollback)
  }

  @MainActor @Test func pendingWriteDefersVerificationWithoutSpendingRetryAndSiblingStillSettles() async {
    let (platform, reads, id, start) = await fixture()
    defer { platform.frameCoordinator.drain() }
    let engine = platform.snapshotEngine
    let sibling = WindowID(rawValue: 4102)
    let siblingTarget = Rect(x: 2000, y: 37, width: 752, height: 902)
    let nextTarget = Rect(x: 8, y: 37, width: 752, height: 902)
    reads.state.withLock { $0.now = start + 0.1 }
    platform.frameCoordinator.running = true
    await platform.apply([FrameAssignment(windowID: id, frame: nextTarget),
      FrameAssignment(windowID: sibling, frame: siblingTarget)], positionsOnly: true, updateVisibility: false)
    engine.registerFrameCommit(FrameCommitExpectation(commitID: 999, from: siblingTarget,
      target: siblingTarget, issuedAt: start, deadline: start + 0.8, observedAt: nil), for: sibling)
    #expect(platform.frameCoordinator.pendingWindowIDs == [id])
    reads.state.withLock { $0.now = start + 1 }
    let waiting = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(waiting.windows.first { $0.id == id }?.frame == target)
    #expect(waiting.windows.first { $0.id == sibling }?.frame == siblingTarget)
    #expect(waiting.targetMismatches.isEmpty)
    #expect(engine.frameCommitExpectations[id]?.verificationAttempts == 0)
    #expect(engine.frameCommitExpectations[sibling] == nil)
    platform.frameCoordinator.drain()
    reads.state.withLock { $0.now = start + 1.5 }
    let final = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(final.windows.first { $0.id == id }?.frame == nextTarget)
    #expect(engine.frameCommitExpectations[id] == nil)
    #expect(!engine.pendingFrameDebtWindowIDs.contains(id))
  }

  @MainActor @Test(arguments: ["input", "process-event", "same-target", "new-target"])
  func supersededReadCannotRetireOrCorrectCurrentCommit(cause: String) async throws {
    let (platform, reads, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    let originalExpectation = try #require(engine.frameCommitExpectations[id])
    let nextTarget = cause == "new-target" ? Rect(x: 8, y: 37, width: 752, height: 902) : target
    let once = Mutex(false)
    var access = engine.discoveryMeasurementAccess!
    let attributes = access.windowAttributes
    access.windowAttributes = { @Sendable element, pid in
      let result = attributes(element, pid)
      let first = once.withLock { value in
        if value { return false }
        value = true
        return true
      }
      if first {
        switch cause {
        case "input": engine.userInputTracker.invalidate(at: start + 1)
        case "process-event": engine.recordObservation(.frame, processID: pid, windowID: id)
        default:
          engine.targetFrames[id] = nextTarget
          engine.registerFrameCommit(FrameCommitExpectation(commitID: originalExpectation.commitID + 1,
            from: originalExpectation.from, target: nextTarget, issuedAt: originalExpectation.issuedAt,
            deadline: start + 1.7, observedAt: nil), for: id)
        }
      }
      return result
    }
    engine.discoveryMeasurementAccess = access
    setFrame(rollback, id: id, reads: reads)
    reads.state.withLock { $0.now = start + 0.9 }
    let stale = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(stale.targetMismatches.isEmpty)
    #expect(engine.pendingFrameCorrections[id] == nil)
    #expect(engine.frameCommitExpectations[id]?.target == nextTarget)
    #expect(engine.frameCommitExpectations[id]?.verificationAttempts == 0)
    reads.state.withLock { $0.now = start + 1.8 }
    let current = engine.snapshot(config: Config(), forceFullWindowRefresh: false)
    #expect(current.targetMismatches == [FrameMismatch(windowID: id, actual: rollback, target: nextTarget)])
    #expect(engine.pendingFrameCorrections[id] == rollback)
    #expect(engine.pendingFrameDebtWindowIDs.contains(id))
  }

  @MainActor @Test(arguments: ["withdraw", "element", "pid", "application", "hidden", "destroy", "terminate", "session", "display"])
  func invalidatedCommitCannotReintroduceDebt(cause: String) async throws {
    let (platform, _, id, start) = await fixture()
    defer { withExtendedLifetime(platform) {} }
    let engine = platform.snapshotEngine
    let read = try #require(engine.captureFrameCommitReads()[id])
    switch cause {
    case "withdraw": engine.targetFrames[id] = nil
    case "element": engine.elements[id] = AXUIElementCreateApplication(-999)
    case "pid": engine.processIDs[id] = 99
    case "application": engine.applications[41] = AXUIElementCreateApplication(-999)
    case "hidden": engine.lastHiddenWindowIDs = [id]
    case "destroy": engine.recordObservation(.windows, processID: 41, windowID: id)
    case "terminate": engine.recordObservation(.applicationTerminated, processID: 41)
    case "session": engine.invalidateAccessibilitySession()
    default: await platform.invalidateFrameStateForDisplayChange()
    }
    #expect(engine.frameCommitExpectations[id] == nil)
    if case .stale = engine.observeFrameCommit(read, actual: rollback, sampledAt: start + 0.9,
      now: start + 0.9, externalGesture: false) {} else { Issue.record("Invalidated read was accepted") }
    engine.finishFrameCommitReads([id: read], attemptedWindowIDs: [id], now: start + 0.9)
    #expect(engine.pendingFrameCorrections[id] == nil)
    #expect(!engine.pendingFrameDebtWindowIDs.contains(id))
    #expect(engine.frameCommitExpectations[id] == nil)
  }

}
