import DefiRuntime
import Testing
@testable import DefiMacOS

@MainActor
struct DelayedObservationCampaignRegressionTests {
  @Test func finishedCampaignsDeliverBeforeRetiringTheirIdentities() {
    let platform = NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { MacOSPlatform() } }
    let clock = VirtualObservationClock()
    clock.attach(platform)
    let campaigns = platform.delayedObservationCampaigns
    var deliveredGenerations: [ObservationRetryLane: UInt64] = [:]
    for pid in 1...128 {
      let lane = ObservationRetryLane.creation(Int32(pid))
      campaigns.merge(lane: lane, delays: [10], platform: platform) { _, generation in
        deliveredGenerations[lane] = generation
        platform.deliverObservation {
          if campaigns.isCurrent(lane, generation: generation) {
            clock.counts.withLock { $0.handlers += 1 }
          }
        }
      }
    }
    clock.advance(0.01, platform, deliver: false)
    #expect(clock.counts.withLock { $0.handlers } == 0)
    #expect(deliveredGenerations.count == 128)
    #expect(deliveredGenerations.allSatisfy { campaigns.isCurrent($0.key, generation: $0.value) })
    clock.flush(platform)
    #expect(clock.counts.withLock { $0.handlers } == 128)
    #expect(deliveredGenerations.allSatisfy { !campaigns.isCurrent($0.key, generation: $0.value) })
    #expect(clock.timers.isEmpty)
  }

  @Test(arguments: [false, true])
  func replacedCampaignRejectsOldDeliveryAndOldRetirement(retireBeforeRestart: Bool) {
    let platform = NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { MacOSPlatform() } }
    let clock = VirtualObservationClock()
    clock.attach(platform)
    let campaigns = platform.delayedObservationCampaigns
    let lane = ObservationRetryLane.creation(42)
    var oldGeneration: UInt64?
    campaigns.merge(lane: lane, delays: [10], platform: platform) { _, generation in
      oldGeneration = generation
      platform.deliverObservation {
        if campaigns.isCurrent(lane, generation: generation) {
          clock.counts.withLock { $0.handlers += 1 }
        }
      }
    }
    clock.advance(0.01, platform, deliver: false)
    if retireBeforeRestart { clock.flush(platform) }
    var newGeneration: UInt64?
    campaigns.merge(lane: lane, delays: [10], platform: platform) { _, generation in
      newGeneration = generation
      platform.deliverObservation {
        if campaigns.isCurrent(lane, generation: generation) {
          clock.counts.withLock { $0.handlers += 1 }
        }
      }
    }
    clock.flush(platform)
    #expect(clock.counts.withLock { $0.handlers } == (retireBeforeRestart ? 1 : 0))
    clock.advance(0.02, platform)
    #expect(clock.counts.withLock { $0.handlers } == (retireBeforeRestart ? 2 : 1))
    #expect(oldGeneration != newGeneration)
    #expect(clock.timers.isEmpty)
  }
}
