import DefiRuntime
import Testing
@testable import DefiMacOS

struct ObservationCampaignRegressionTests {
  @MainActor @Test
  func queuedFocusRetryRejectsNewerEventAtNavigationDelivery() {
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    let clock = VirtualObservationClock()
    clock.attach(platform)
    platform.observationMeasurementAccess!.receive!(.focus, 41, nil)
    clock.flush(platform)
    clock.advance(0.05, platform, deliver: false)
    platform.observationMeasurementAccess!.receive!(.focus, 42, nil)
    clock.flush(platform)
    #expect(clock.counts.withLock { $0.handlers } == 2)
    platform.snapshotEngine.nativeFocusEventPending = false
    clock.advance(12.1, platform)
    #expect(!platform.nativeFocusEventPending)
    #expect(clock.counts.withLock { $0.handlers } == 2)
  }

  @MainActor @Test
  func creationDeadlinesStayEarlyAndIndependentOfFocusAndLifecycle() {
    let platform = NavigationActor.shared.queue.sync {
      NavigationActor.assumeIsolated { MacOSPlatform() }
    }
    platform.applicationWindowCounts = [41: 0, 42: 0]
    let clock = VirtualObservationClock()
    clock.attach(platform)
    platform.observationMeasurementAccess!.receive!(.windowCreated, 41, nil)
    clock.flush(platform)
    clock.advance(0.02, platform)
    platform.observationMeasurementAccess!.receive!(.windowCreated, 42, nil)
    clock.flush(platform)
    clock.advance(0.04, platform)
    platform.observationMeasurementAccess!.receive!(.windowCreated, 41, nil)
    platform.observationMeasurementAccess!.receive!(.applicationTerminated, 41, nil)
    platform.observationMeasurementAccess!.receive!(.application, nil, nil)
    clock.flush(platform)
    clock.advance(0.05, platform)
    #expect(clock.counts.withLock { $0.handlers } == 6)
    clock.advance(12.1, platform)
    #expect(clock.delayedCreationCoverage == [41, 42])
    #expect(clock.timers.isEmpty)
    #expect(clock.maximumPending <= 4)
  }
}
