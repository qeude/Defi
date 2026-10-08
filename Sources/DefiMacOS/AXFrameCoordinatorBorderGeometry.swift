import ApplicationServices
import DefiModel
import Foundation

struct BorderGeometryReadTarget: Equatable, @unchecked Sendable {
  let windowID: WindowID
  let processID: pid_t
  let application: AXUIElement
  let element: AXUIElement
  let bindingRevision: UInt64

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.windowID == rhs.windowID && lhs.processID == rhs.processID
      && lhs.bindingRevision == rhs.bindingRevision
      && CFEqual(lhs.application, rhs.application) && CFEqual(lhs.element, rhs.element)
  }
}

struct BorderGeometryReadTicket: Equatable, Sendable {
  let target: BorderGeometryReadTarget
  let generation: UInt64
}

struct BorderGeometryObservation: Equatable, Sendable {
  let ticket: BorderGeometryReadTicket
  let sampledAt: TimeInterval
  let frame: Rect
  var windowID: WindowID { ticket.target.windowID }
}

struct BorderGeometryReadLane {
  var pending: [WindowID: BorderGeometryReadTicket] = [:]
  var order: [WindowID] = []
  var scheduled = false

  mutating func enqueue(_ ticket: BorderGeometryReadTicket) {
    if pending[ticket.target.windowID] == nil { order.append(ticket.target.windowID) }
    pending[ticket.target.windowID] = ticket
  }

  mutating func take() -> BorderGeometryReadTicket? {
    guard !order.isEmpty else { return nil }
    return pending.removeValue(forKey: order.removeFirst())
  }

  mutating func retain(_ windowIDs: Set<WindowID>) {
    pending = pending.filter { windowIDs.contains($0.key) }
    order.removeAll { !windowIDs.contains($0) }
  }
}

extension AXFrameCoordinator {
  func requestBorderGeometry(_ targets: [BorderGeometryReadTarget]) {
    var starts: [(pid_t, ProcessWriteQueueReservation)] = []
    lock.lock()
    for target in targets {
      var lane = borderReadLanes[target.processID] ?? BorderGeometryReadLane()
      lane.enqueue(BorderGeometryReadTicket(target: target, generation: latestGeneration))
      if !lane.scheduled {
        lane.scheduled = true
        borderGeometryReadGroup.enter()
        starts.append((target.processID, reserveProcessWriteQueueLocked(for: target.processID)))
      }
      borderReadLanes[target.processID] = lane
    }
    lock.unlock()
    for (processID, reservation) in starts {
      enqueueBorderGeometryRead(processID: processID, reservation: reservation)
    }
  }

  private func enqueueBorderGeometryRead(
    processID: pid_t, reservation: ProcessWriteQueueReservation
  ) {
    reservation.queue.async { [self, reservation] in
      defer { reservation.release(); borderGeometryReadGroup.leave() }
      lock.lock()
      let ticket = borderReadLanes[processID]?.take()
      lock.unlock()
      var observation: BorderGeometryObservation?
      if let ticket, isCurrent(generation: ticket.generation),
        borderBindingIsCurrent(ticket.target) {
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let frame = borderNativeFrameReader(ticket.target.windowID).flatMap(validatedWindowFrame)
          ?? AXMessagingTimeoutAccess.shared.withTimeout(
            0.025, elements: [ticket.target.application, ticket.target.element]
          ) { accessibilityWriter.readFrame(ticket.target.element) }
        if let frame, borderBindingIsCurrent(ticket.target) {
          observation = BorderGeometryObservation(ticket: ticket, sampledAt: sampledAt, frame: frame)
        }
      }
      var needsDelivery = false
      var successor: ProcessWriteQueueReservation?
      lock.lock()
      if let observation, observation.ticket.generation == latestGeneration,
        observation.sampledAt >= max(
          borderObservationMailbox[observation.windowID]?.sampledAt ?? -.infinity,
          borderReadFreshness[observation.windowID]?.sampledAt ?? -.infinity) {
        borderObservationMailbox[observation.windowID] = observation
        borderReadFreshness[observation.windowID] = (observation.ticket, observation.sampledAt)
        if !borderObservationDeliveryScheduled {
          borderObservationDeliveryScheduled = true
          needsDelivery = true
        }
      }
      if borderReadLanes[processID]?.pending.isEmpty == false {
        borderGeometryReadGroup.enter()
        successor = reserveProcessWriteQueueLocked(for: processID)
      } else {
        borderReadLanes[processID] = nil
      }
      lock.unlock()
      if needsDelivery { scheduleBorderObservationDelivery() }
      if let successor {
        enqueueBorderGeometryRead(processID: processID, reservation: successor)
      }
    }
  }

  private func scheduleBorderObservationDelivery() {
    borderObservationScheduler { [self] in
      let observations = takeBorderGeometryObservations()
      if !observations.isEmpty { borderObservationHandler?(observations) }
    }
  }

  private func takeBorderGeometryObservations() -> [BorderGeometryObservation] {
    lock.lock()
    defer { lock.unlock() }
    let observations = Array(borderObservationMailbox.values)
    borderObservationMailbox.removeAll(keepingCapacity: true)
    borderObservationDeliveryScheduled = false
    return observations
  }

  func forgetBorderGeometry(for windowIDs: Set<WindowID>) {
    guard !windowIDs.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    for processID in Array(borderReadLanes.keys) {
      let retained = Set(borderReadLanes[processID]?.pending.keys.map { $0 } ?? [])
        .subtracting(windowIDs)
      borderReadLanes[processID]?.retain(retained)
    }
    for windowID in windowIDs {
      borderObservationMailbox[windowID] = nil
      borderReadFreshness[windowID] = nil
      borderGeometries[windowID] = nil
      borderGeometryWrittenAt[windowID] = nil
      completedPositions[windowID] = nil
      completedSizes[windowID] = nil
    }
  }

  func observationIsCurrentLocked(_ observation: BorderGeometryObservation) -> Bool {
    let pending = borderReadFreshness[observation.windowID]
    let pendingSampledAt = pending?.ticket == observation.ticket ? pending?.sampledAt : nil
    return observation.ticket.generation == latestGeneration
      && observation.sampledAt >= max(
        max(borderGeometries[observation.windowID]?.sampledAt ?? -.infinity,
          borderGeometryWrittenAt[observation.windowID] ?? -.infinity),
        pendingSampledAt ?? -.infinity)
  }

  func acceptBorderObservationLocked(_ observation: BorderGeometryObservation,
    completingWrite: Bool = false) -> Bool {
    guard observationIsCurrentLocked(observation) else { return false }
    let windowID = observation.windowID
    borderGeometries[windowID] = (observation.frame, observation.sampledAt)
    if completingWrite {
      completedPositions[windowID] = CGPoint(x: observation.frame.x, y: observation.frame.y)
      completedSizes[windowID] = CGSize(width: observation.frame.width, height: observation.frame.height)
      borderGeometryWrittenAt[windowID] = observation.sampledAt
    }
    return true
  }
}
