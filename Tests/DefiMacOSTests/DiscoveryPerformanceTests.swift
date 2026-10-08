import ApplicationServices
import DefiConfig
import DefiModel
import DefiRuntime
import Synchronization
import Testing

@testable import DefiMacOS

func emitDiscoveryPerformance(_ name: String, operations: Int, output: [String: Int], metrics: [String: Double]) {
  guard ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1" else { return }
  let record: [String: Any] = ["case": name, "operations": operations, "errors": 0,
                             "output": output, "metrics": metrics]
  let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
  print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
}

@MainActor
final class VirtualObservationClock {
  var now = 0.0
  var timers: [(Double, Int, @MainActor @Sendable () -> Void)] = []
  var deliveries: [@NavigationActor @Sendable () -> Void] = []
  var scheduled = 0
  var fired = 0
  var maximumPending = 0
  var delayedCreationCoverage = Set<pid_t>()
  var firedAt: [Double] = []
  nonisolated let counts = Mutex((handlers: 0, globals: 0))

  func attach(_ platform: MacOSPlatform) {
    let access = ObservationMeasurementAccess()
    access.now = { self.now }
    access.schedule = { delay, body in
      self.scheduled += 1
      let identifier = self.scheduled
      self.timers.append((self.now + Double(delay) / 1000, self.scheduled, body))
      self.maximumPending = max(self.maximumPending, self.timers.count)
      return { self.timers.removeAll { $0.1 == identifier } }
    }
    access.deliver = { self.deliveries.append($0) }
    platform.observationMeasurementAccess = access
    let engine = platform.snapshotEngine
    platform.presentStartObserving {
      let observations = engine.consumeObservations()
      self.counts.withLock {
        $0.handlers += 1
        if observations.topologyRequiresFullSnapshot { $0.globals += 1 }
      }
    }
  }

  func flush(_ platform: MacOSPlatform) {
    let pending = platform.snapshotEngine.pendingObservations
    if now >= 0.15 { delayedCreationCoverage.formUnion(pending.topologyProcessIDs) }
    while !deliveries.isEmpty {
      let body = deliveries.removeFirst()
      NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { body() } }
    }
  }

  func advance(_ target: Double, _ platform: MacOSPlatform, deliver: Bool = true) {
    while let next = timers.indices.min(by: {
      (timers[$0].0, timers[$0].1) < (timers[$1].0, timers[$1].1)
    }), timers[next].0 <= target + 0.000000001 {
      let timer = timers.remove(at: next)
      now = timer.0
      fired += 1
      firedAt.append(now)
      timer.2()
      if deliver { flush(platform) }
    }
    now = max(now, target)
  }
}

struct DiscoveryPerformanceTests {
  @MainActor @Test
  func observationCampaignsPerformance() {
    for overlapping in [false, true] {
      let start = ProcessInfo.processInfo.systemUptime
      let platform = NavigationActor.shared.queue.sync {
        NavigationActor.assumeIsolated { MacOSPlatform() }
      }
      platform.applicationWindowCounts = [41: 0, 42: 0]
      let clock = VirtualObservationClock()
      clock.attach(platform)
      let count = overlapping ? 100 : 1
      for index in 0..<count {
        clock.advance(Double(index) / 1000, platform)
        let pid = pid_t(index % 2 == 0 ? 41 : 42)
        platform.observationMeasurementAccess!.receive!(.focus, pid, nil)
        platform.observationMeasurementAccess!.receive!(.application, pid, nil)
        if index < 2 || !overlapping {
          platform.observationMeasurementAccess!.receive!(.windowCreated, pid, nil)
        }
        clock.flush(platform)
      }
      clock.advance(12.1, platform)
      #expect(clock.timers.isEmpty)
      #expect(clock.delayedCreationCoverage == (overlapping ? [41, 42] : [41]))
      #expect(platform.nativeFocusEventPending)
      let counts = clock.counts.withLock { $0 }
      emitDiscoveryPerformance(overlapping ? "observations-overlapping" : "observations-isolated",
        operations: count * 2 + (overlapping ? 2 : 1),
        output: ["creation_pids": clock.delayedCreationCoverage.count, "pending_focus": 1, "timers_left": 0],
        metrics: ["scheduled": Double(clock.scheduled), "fired": Double(clock.fired),
                  "handlers": Double(counts.handlers), "global_invalidations": Double(platform.snapshotEngine.preparedWindowReadRevisions.global),
                  "maximum_pending": Double(clock.maximumPending),
                  "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
    }
    let lateStarted = ProcessInfo.processInfo.systemUptime
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    platform.applicationWindowCounts = [41: 0, 42: 0]
    let clock = VirtualObservationClock()
    clock.attach(platform)
    for (time, pid) in [(0.0, pid_t(41)), (11.9, pid_t(42))] {
      clock.advance(time, platform)
      platform.observationMeasurementAccess!.receive!(.focus, pid, nil)
      clock.flush(platform)
    }
    clock.advance(23.9, platform)
    #expect(clock.timers.isEmpty)
    #expect(clock.firedAt.contains { abs($0 - 12) < 0.001 })
    #expect(clock.firedAt.contains { abs($0 - 23.9) < 0.001 })
    let creationPlatform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    creationPlatform.applicationWindowCounts = [41: 0]
    let creationClock = VirtualObservationClock()
    creationClock.attach(creationPlatform)
    creationPlatform.observationMeasurementAccess!.receive!(.windowCreated, 41, nil)
    creationClock.flush(creationPlatform)
    creationClock.advance(0.34, creationPlatform)
    creationPlatform.observationMeasurementAccess!.receive!(.windowCreated, 41, nil)
    creationClock.flush(creationPlatform)
    creationClock.advance(0.7, creationPlatform)
    #expect(creationClock.timers.isEmpty)
    #expect(creationClock.firedAt.contains { abs($0 - 0.35) < 0.001 })
    #expect(creationClock.firedAt.contains { abs($0 - 0.69) < 0.001 })
    let lifecyclePlatform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let lifecycleClock = VirtualObservationClock()
    lifecycleClock.attach(lifecyclePlatform)
    lifecyclePlatform.observationMeasurementAccess!.receive!(.application, 41, nil)
    lifecycleClock.flush(lifecyclePlatform)
    lifecycleClock.advance(11.9, lifecyclePlatform)
    lifecyclePlatform.observationMeasurementAccess!.receive!(.applicationTerminated, 41, nil)
    lifecycleClock.flush(lifecyclePlatform)
    lifecycleClock.advance(23.9, lifecyclePlatform)
    #expect(lifecycleClock.timers.isEmpty)
    #expect(lifecycleClock.firedAt.contains { abs($0 - 12) < 0.001 })
    #expect(lifecycleClock.firedAt.contains { abs($0 - 23.9) < 0.001 })
    emitDiscoveryPerformance("observations-late", operations: 6,
      output: ["earliest_focus_tail": 1, "latest_focus_tail": 1,
               "earliest_creation_tail": 1, "latest_creation_tail": 1,
               "earliest_lifecycle_tail": 1, "latest_lifecycle_tail": 1],
      metrics: ["scheduled": Double(clock.scheduled + creationClock.scheduled + lifecycleClock.scheduled),
                "fired": Double(clock.fired + creationClock.fired + lifecycleClock.fired),
                "handlers": Double(clock.counts.withLock { $0.handlers } + creationClock.counts.withLock { $0.handlers } + lifecycleClock.counts.withLock { $0.handlers }),
                "global_invalidations": Double(lifecyclePlatform.snapshotEngine.preparedWindowReadRevisions.global),
                "maximum_pending": Double(max(clock.maximumPending, creationClock.maximumPending, lifecycleClock.maximumPending)),
                "elapsed_ms": (ProcessInfo.processInfo.systemUptime - lateStarted) * 1000])

  }
}
