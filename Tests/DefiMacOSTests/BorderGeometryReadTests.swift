import AppKit
import ApplicationServices
import DefiCore
import DefiModel
import DefiRuntime
import Synchronization
import Testing

@testable import DefiMacOS

private final class HeldBorderDeliveries: @unchecked Sendable {
  private let pending = Mutex<[@MainActor @Sendable () -> Void]>([])
  func schedule(_ delivery: @escaping @MainActor @Sendable () -> Void) {
    pending.withLock { $0.append(delivery) }
  }
  var count: Int { pending.withLock { $0.count } }
  @MainActor func deliver() {
    let callbacks = pending.withLock { value in
      let callbacks = value
      value.removeAll()
      return callbacks
    }
    for callback in callbacks { callback() }
  }
}

struct BorderGeometryReadTests {
  private let id = WindowID(rawValue: 1)
  private let value = Rect(x: 120, y: 40, width: 650, height: 700)

  private func engine(_ coordinator: AXFrameCoordinator, ids: [WindowID] = [WindowID(rawValue: 1)],
    processIDs: [pid_t] = [-41]) -> SnapshotEngine {
    let engine = SnapshotEngine(frameCoordinator: coordinator, userInputTracker: UserInputTracker())
    bind(engine, ids: ids, processIDs: processIDs)
    coordinator.borderBindingIsCurrent = { [weak engine] in engine?.borderBindingIsCurrent($0) == true }
    return engine
  }

  private func bind(_ engine: SnapshotEngine, ids: [WindowID], processIDs: [pid_t]) {
    engine.elements = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
      ($0.element, AXUIElementCreateApplication(-100 - pid_t($0.offset)))
    })
    engine.processIDs = Dictionary(uniqueKeysWithValues: ids.enumerated().map {
      ($0.element, processIDs[$0.offset % processIDs.count])
    })
    engine.applications = Dictionary(uniqueKeysWithValues: Set(processIDs).map {
      ($0, AXUIElementCreateApplication($0))
    })
  }

  private func wire(_ coordinator: AXFrameCoordinator, engine: SnapshotEngine,
    deliveries: HeldBorderDeliveries) {
    coordinator.borderObservationScheduler = { deliveries.schedule($0) }
    coordinator.borderObservationHandler = { observations in
      for observation in observations { _ = engine.acceptBorderObservation(observation) }
    }
  }

  @Test @MainActor func notificationIngressCoalescesBeforeReadsAndWriterRenderingIsCacheOnly() {
    let calls = Mutex(0), held = HeldBorderDeliveries()
    let coordinator = AXFrameCoordinator()
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform(frameCoordinator: coordinator) }
    }
    bind(platform.snapshotEngine, ids: [id], processIDs: [-41])
    let accepted = Rect(x: -9900, y: -10000, width: 650, height: 700)
    coordinator.borderNativeFrameReader = { _ in
      #expect(!Thread.isMainThread)
      calls.withLock { $0 += 1 }
      return accepted
    }
    coordinator.borderObservationScheduler = { held.schedule($0) }
    let style = WindowBorderStyle(enabled: true, width: 1, activeColor: 0,
      inactiveEnabled: false, inactiveColor: 0, captureEnabled: false)
    let assignment = FrameAssignment(windowID: id,
      frame: Rect(x: -10000, y: -10000, width: 650, height: 700))
    platform.borderManager.sync(
      WindowBorderRenderPlan(active: assignment, inactive: [], tracked: [assignment], style: style),
      displayedFrames: [id: assignment.frame], stacking: .inactive(for: id)
    )
    defer { platform.borderManager.hide() }
    #expect(platform.borderManager.liveGeometryWindowIDs == [id])
    for _ in 0..<500 { platform.enqueueBorderGeometry([id], requiresNativeRead: true) }
    #expect(calls.withLock { $0 } == 0)
    platform.deliverPendingBorderGeometry()
    coordinator.borderGeometryReadGroup.wait()
    #expect(calls.withLock { $0 } == 1)
    #expect(held.count == 1)
    held.deliver()
    #expect(platform.snapshotEngine.latestObservedFrames[id] == accepted)
    #expect(coordinator.latestBorderFrame(for: id) == accepted)
    let geometryUpdates = platform.borderManager.performance.geometryUpdates
    #expect(geometryUpdates == 1)
    for _ in 0..<500 { platform.enqueueBorderGeometry([id]) }
    platform.deliverPendingBorderGeometry()
    coordinator.borderGeometryReadGroup.wait()
    #expect(calls.withLock { $0 } == 1)
    #expect(platform.borderManager.performance.geometryUpdates == geometryUpdates)
    platform.enqueueBorderGeometry([id], requiresNativeRead: true)
    platform.deliverPendingBorderGeometry()
    coordinator.borderGeometryReadGroup.wait()
    coordinator.forgetBorderGeometry(for: [id])
    platform.snapshotEngine.latestObservedFrames = [:]
    platform.borderManager.hide()
    held.deliver()
    #expect(coordinator.latestBorderFrame(for: id) == nil)
    #expect(platform.snapshotEngine.latestObservedFrames[id] == nil)
  }

  @Test @MainActor func mouseDragAndReleaseSampleNativeGeometryWithoutNotificationsOrSnapshotCompletion() throws {
    let held = HeldBorderDeliveries(), reads = Mutex(0)
    let duringDrag = Rect(x: -9900, y: -10000, width: 650, height: 700)
    let afterRelease = Rect(x: -9800, y: -10000, width: 680, height: 700)
    let native = Mutex(duringDrag)
    let coordinator = AXFrameCoordinator()
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform(frameCoordinator: coordinator) }
    }
    bind(platform.snapshotEngine, ids: [id], processIDs: [-41])
    coordinator.borderNativeFrameReader = { _ in
      #expect(!Thread.isMainThread)
      reads.withLock { $0 += 1 }
      return native.withLock { $0 }
    }
    coordinator.borderObservationScheduler = { held.schedule($0) }
    let style = WindowBorderStyle(enabled: true, width: 1, activeColor: 0,
      inactiveEnabled: false, inactiveColor: 0, captureEnabled: false)
    let assignment = FrameAssignment(windowID: id,
      frame: Rect(x: -10000, y: -10000, width: 650, height: 700))
    platform.borderManager.sync(
      WindowBorderRenderPlan(active: assignment, inactive: [], tracked: [assignment], style: style),
      displayedFrames: [id: assignment.frame], stacking: .inactive(for: id))
    defer { platform.borderManager.hide() }
    let pendingSnapshotEvents = Mutex<[PlatformEventKind]>([])
    let engine = platform.snapshotEngine
    let monitor = platform.makeEventMonitor(handler: { kind, pid in
      pendingSnapshotEvents.withLock { $0.append(kind) }
      engine.recordObservation(kind, processID: pid)
    })
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
      if type == .leftMouseUp { native.withLock { $0 = afterRelease } }
      let event = try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
      monitor.handleMouseEvent(event)
      if type == .leftMouseDown { continue }
      platform.deliverPendingBorderGeometry()
      coordinator.borderGeometryReadGroup.wait()
      held.deliver()
      let expected = type == .leftMouseDragged ? duringDrag : afterRelease
      #expect(engine.latestObservedFrames[id] == expected)
      #expect(coordinator.latestBorderFrame(for: id) == expected)
      #expect(platform.borderManager.performance.geometryUpdates == (type == .leftMouseDragged ? 1 : 2))
      #expect(engine.pendingObservations.framePending)
    }
    #expect(pendingSnapshotEvents.withLock { $0 } == [.mouse, .mouse, .mouseRelease])
    #expect(reads.withLock { $0 } == 2)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test @MainActor func burstKeepsOneSuccessorAndYieldsToPIDWritesAndOtherDirtyWindows() {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let reads = Mutex(0), order = Mutex<[String]>([]), held = HeldBorderDeliveries()
    let coordinator = AXFrameCoordinator()
    let second = WindowID(rawValue: 2)
    let engine = engine(coordinator, ids: [id, second])
    let accepted = value
    coordinator.borderNativeFrameReader = { id in
      let index = reads.withLock { $0 += 1; return $0 }
      order.withLock { $0.append("read\(id.rawValue)") }
      if index == 1 {
        entered.signal()
        #expect(resume.wait(timeout: .now() + 3) == .success)
      }
      return accepted
    }
    wire(coordinator, engine: engine, deliveries: held)
    let target = engine.borderGeometryTargets(for: [id])
    coordinator.requestBorderGeometry(target)
    #expect(entered.wait(timeout: .now() + 3) == .success)
    let write = coordinator.reserveProcessWriteQueue(for: -41)
    write.queue.async {
      order.withLock { $0.append("write") }
      write.release()
    }
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [second]))
    for _ in 0..<500 { coordinator.requestBorderGeometry(target) }
    resume.signal()
    coordinator.borderGeometryReadGroup.wait()
    #expect(order.withLock { $0 } == ["read1", "write", "read2", "read1"])
    #expect(reads.withLock { $0 } == 3)
    #expect(held.count == 1)
    held.deliver()
    #expect(engine.latestObservedFrames == [id: value, second: value])
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test @MainActor func sustainedDragPublishesValidSampleWhileItsSuccessorIsStillReading() {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let reads = Mutex(0), held = HeldBorderDeliveries()
    let coordinator = AXFrameCoordinator(), engine = engine(coordinator)
    coordinator.borderNativeFrameReader = { _ in
      let index = reads.withLock { $0 += 1; return $0 }
      entered.signal()
      #expect(resume.wait(timeout: .now() + 3) == .success)
      return Rect(x: Double(index * 10), y: 40, width: 650, height: 700)
    }
    wire(coordinator, engine: engine, deliveries: held)
    let targets = engine.borderGeometryTargets(for: [id])
    coordinator.requestBorderGeometry(targets)
    #expect(entered.wait(timeout: .now() + 3) == .success)
    coordinator.requestBorderGeometry(targets)
    resume.signal()
    #expect(entered.wait(timeout: .now() + 3) == .success)
    held.deliver()
    #expect(engine.latestObservedFrames[id] == Rect(x: 10, y: 40, width: 650, height: 700))
    coordinator.requestBorderGeometry(targets)
    resume.signal()
    #expect(entered.wait(timeout: .now() + 3) == .success)
    held.deliver()
    #expect(engine.latestObservedFrames[id] == Rect(x: 20, y: 40, width: 650, height: 700))
    resume.signal()
    coordinator.borderGeometryReadGroup.wait()
    held.deliver()
    #expect(engine.latestObservedFrames[id] == Rect(x: 30, y: 40, width: 650, height: 700))
    #expect(coordinator.completedPosition(for: id) == nil)
  }

  @Test @MainActor func blockedPublicationRetainsOnlyNewestSamplePerWindow() {
    let reads = Mutex(0), held = HeldBorderDeliveries()
    let coordinator = AXFrameCoordinator(), engine = engine(coordinator)
    coordinator.borderNativeFrameReader = { _ in
      let index = reads.withLock { $0 += 1; return $0 }
      return Rect(x: Double(index), y: 40, width: 650, height: 700)
    }
    wire(coordinator, engine: engine, deliveries: held)
    for _ in 0..<20 {
      coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
      coordinator.borderGeometryReadGroup.wait()
    }
    #expect(held.count == 1)
    coordinator.lock.lock()
    let mailboxCount = coordinator.borderObservationMailbox.count
    coordinator.lock.unlock()
    #expect(mailboxCount == 1)
    held.deliver()
    #expect(engine.latestObservedFrames[id] == Rect(x: 20, y: 40, width: 650, height: 700))
    #expect(coordinator.processWriteQueueReservations.isEmpty)
  }

  @Test @MainActor func missingNativeBoundsFallsBackToAXOffMainAndFailureReleasesRetiredLane() {
    let reads = Mutex(0), held = HeldBorderDeliveries(), accepted = value
    let coordinator = AXFrameCoordinator(accessibilityWriter: AXFrameAccessibilityWriter(
      frameReader: { _ in
        #expect(!Thread.isMainThread)
        let index = reads.withLock { $0 += 1; return $0 }
        return index == 1 ? accepted : nil
      }
    ))
    let engine = engine(coordinator)
    coordinator.borderNativeFrameReader = { _ in nil }
    wire(coordinator, engine: engine, deliveries: held)
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    coordinator.borderGeometryReadGroup.wait()
    held.deliver()
    #expect(engine.latestObservedFrames[id] == value)
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    coordinator.borderGeometryReadGroup.wait()
    held.deliver()
    #expect(reads.withLock { $0 } == 2)
    #expect(engine.latestObservedFrames[id] == value)
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    #expect(coordinator.processWriteQueueReservations.isEmpty)
    #expect(coordinator.processWriteQueues.isEmpty)
  }

  @Test(arguments: ["write", "observation", "generation", "element", "remove", "reset", "pid-reuse", "termination", "destroyed"])
  @MainActor func stalePublicationCannotRepopulateGeometry(cause: String) {
    let coordinator = AXFrameCoordinator(), engine = engine(coordinator), held = HeldBorderDeliveries()
    let accepted = value
    coordinator.borderNativeFrameReader = { _ in accepted }
    wire(coordinator, engine: engine, deliveries: held)
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    coordinator.borderGeometryReadGroup.wait()
    held.deliver()
    #expect(engine.latestObservedFrames[id] == value)
    engine.latestObservedFrames = [:]
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    coordinator.borderGeometryReadGroup.wait()
    let replacement = Rect(x: 500, y: 40, width: 650, height: 700)
    switch cause {
    case "write":
      coordinator.recordCompletedPosition(CGPoint(x: 500, y: 40), windowID: id)
    case "observation":
      coordinator.recordObservedBorderFrame(replacement, windowID: id,
        sampledAt: ProcessInfo.processInfo.systemUptime)
    case "generation": coordinator.invalidate(reason: "new-intent")
    case "element": engine.elements = [id: AXUIElementCreateApplication(-999)]
    case "remove":
      let elements = engine.elements
      engine.elements = [:]
      engine.elements = elements
    case "reset":
      let applications = engine.applications
      engine.invalidateAccessibilitySession()
      _ = engine.consumeObservations()
      engine.applications = applications
    case "termination", "destroyed":
      let elements = engine.elements
      engine.recordObservation(cause == "termination" ? .applicationTerminated : .windows,
        processID: -41, windowID: cause == "destroyed" ? id : nil)
      #expect(engine.borderGeometryTargets(for: [id]).isEmpty)
      engine.elements = elements
    case "pid-reuse":
      let applications = engine.applications
      engine.applications = [:]
      engine.applications = applications
    default: Issue.record("Unknown cause")
    }
    held.deliver()
    #expect(engine.latestObservedFrames[id] == nil)
    #expect(coordinator.latestBorderFrame(for: id) ==
      ((cause == "write" || cause == "observation") ? replacement : nil))
  }

  @Test @MainActor func resetDuringReadDiscardsResultAndShutdownDrainsReservation() {
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let drained = DispatchSemaphore(value: 0), held = HeldBorderDeliveries()
    let coordinator = AXFrameCoordinator(), engine = engine(coordinator), accepted = value
    coordinator.borderNativeFrameReader = { _ in
      entered.signal()
      #expect(resume.wait(timeout: .now() + 3) == .success)
      return accepted
    }
    wire(coordinator, engine: engine, deliveries: held)
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    #expect(entered.wait(timeout: .now() + 3) == .success)
    coordinator.requestBorderGeometry(engine.borderGeometryTargets(for: [id]))
    engine.invalidateAccessibilitySession()
    coordinator.pruneProcessLatencyState(liveProcessIDs: [])
    DispatchQueue.global().async {
      coordinator.invalidateAndWaitForWrites()
      drained.signal()
    }
    resume.signal()
    #expect(drained.wait(timeout: .now() + 3) == .success)
    held.deliver()
    #expect(engine.latestObservedFrames[id] == nil)
    #expect(coordinator.latestBorderFrame(for: id) == nil)
    #expect(coordinator.processWriteQueueReservations.isEmpty)
    #expect(coordinator.processWriteQueues.isEmpty)
  }
}
