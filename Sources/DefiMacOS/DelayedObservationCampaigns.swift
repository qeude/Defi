import Foundation
import Synchronization

enum ObservationRetryLane: Hashable, Sendable {
  case focus
  case lifecycle(pid_t?)
  case creation(pid_t)
}

@MainActor
final class DelayedObservationCampaigns {
  struct Stage {
    var earliest: TimeInterval
    var latest: TimeInterval
  }

  struct Campaign {
    var deadlines: [Int: Stage]
    var armedAt: TimeInterval?
    var cancel: (() -> Void)?
    var deliver: @MainActor @Sendable (Int, UInt64) -> Void
  }

  private var campaigns: [ObservationRetryLane: Campaign] = [:]
  private nonisolated let generations = Mutex<[ObservationRetryLane: UInt64]>([:])

  nonisolated func isCurrent(_ lane: ObservationRetryLane, generation: UInt64) -> Bool {
    generations.withLock { $0[lane] == generation }
  }

  func merge(
    lane: ObservationRetryLane, delays: [Int], platform: MacOSPlatform,
    deliver: @escaping @MainActor @Sendable (Int, UInt64) -> Void
  ) {
    let now = platform.observationNow
    generations.withLock { $0[lane, default: 0] &+= 1 }
    var campaign = campaigns[lane] ?? Campaign(deadlines: [:], deliver: deliver)
    for delay in delays {
      let deadline = now + Double(delay) / 1000
      let previous = campaign.deadlines[delay]
      campaign.deadlines[delay] = Stage(
        earliest: min(previous?.earliest ?? deadline, deadline),
        latest: max(previous?.latest ?? deadline, deadline)
      )
    }
    campaign.deliver = deliver
    campaigns[lane] = campaign
    arm(lane: lane, platform: platform)
  }

  private func arm(lane: ObservationRetryLane, platform: MacOSPlatform) {
    guard var campaign = campaigns[lane], let deadline = campaign.deadlines.values.map(\.earliest).min()
    else { return }
    if campaign.armedAt == deadline { return }
    campaign.cancel?()
    campaign.armedAt = deadline
    campaign.cancel = platform.scheduleObservationDelay(
      Int(ceil(max(0, deadline - platform.observationNow) * 1000 - 0.000001))
    ) { [weak self, weak platform] in
      guard let self, let platform, var current = self.campaigns[lane] else { return }
      let due = current.deadlines.filter { $0.value.earliest <= platform.observationNow + 0.000001 }
      for (delay, stage) in due {
        current.deadlines[delay] = stage.latest > platform.observationNow + 0.000001
          ? Stage(earliest: stage.latest, latest: stage.latest) : nil
      }
      current.armedAt = nil
      current.cancel = nil
      let generation = self.generations.withLock { $0[lane]! }
      self.campaigns[lane] = current.deadlines.isEmpty ? nil : current
      for delay in due.keys.sorted() { current.deliver(delay, generation) }
      self.arm(lane: lane, platform: platform)
    }
    campaigns[lane] = campaign
  }
}
