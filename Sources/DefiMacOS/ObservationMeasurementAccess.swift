import ApplicationServices
import DefiRuntime

@MainActor
final class ObservationMeasurementAccess {
  var receive: ((PlatformEventKind, pid_t?, AXUIElement?) -> Void)?
  var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  var schedule: (Int, @escaping @MainActor @Sendable () -> Void) -> (() -> Void) = { delay, work in
    let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
    return { item.cancel() }
  }
  var deliver: (@escaping @NavigationActor @Sendable () -> Void) -> Void = { work in
    NavigationActor.enqueue(work)
  }
}

@MainActor
extension MacOSPlatform {
  var observationNow: TimeInterval {
    observationMeasurementAccess?.now() ?? ProcessInfo.processInfo.systemUptime
  }

  @discardableResult
  func scheduleObservationDelay(_ delay: Int, _ work: @escaping @MainActor @Sendable () -> Void) -> (() -> Void) {
    if let access = observationMeasurementAccess { return access.schedule(delay, work) }
    let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: item)
    return { item.cancel() }
  }

  func deliverObservation(_ work: @escaping @NavigationActor @Sendable () -> Void) {
    if let access = observationMeasurementAccess { access.deliver(work) }
    else { NavigationActor.enqueue(work) }
  }
}
