import Darwin
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

struct BudgetedFreshReadPartitionTests {
  @Test(arguments: [false, true])
  func animationDefersBackgroundReadsWithoutDelayingEventsOrStarvingTheWatchdog(expired: Bool) {
    let pass = budgetedFreshReadPartition(
      requestedProcessIDs: [1, 2], deferredProcessIDs: [3],
      eventPendingProcessIDs: [2, 4], predictedLatencyMS: { _ in 2 },
      budgetMS: 12, defersBackgroundReads: true,
      maximumDeferredAgeSeconds: 0.5, deferredSince: 10,
      now: expired ? 10.6 : 10.2
    )
    #expect(pass.allowedNow == (expired ? [1, 2, 3, 4] : [2, 4]))
    #expect(pass.stillDeferred == (expired ? [] : [1, 3]))
    #expect(pass.deferredSince == (expired ? nil : 10))
    let resumed = budgetedFreshReadPartition(
      requestedProcessIDs: [], deferredProcessIDs: pass.stillDeferred,
      eventPendingProcessIDs: [], predictedLatencyMS: { _ in 2 }, budgetMS: 12,
      maximumDeferredAgeSeconds: 0.5, deferredSince: pass.deferredSince, now: 10.3
    )
    #expect(resumed.allowedNow == pass.stillDeferred)
    #expect(resumed.stillDeferred.isEmpty)
  }

  @Test func dueWindowRetriesDrainAcrossBudgetedPasses() {
    let identities = (1...3).map {
      CGWindowDiscoveryIdentity(windowID: WindowID(rawValue: UInt64($0)),
        processID: pid_t($0), ownerName: "Example", title: "")
    }
    let unresolved = Dictionary(uniqueKeysWithValues: identities.map { ($0, "AX-no-window-match") })
    var tracker = CGWindowDiscoveryRetryTracker()
    tracker.observe(observed: Set(identities), unresolved: unresolved, now: 10)
    for remaining in (1...3).reversed() {
      let due = tracker.dueProcessIDs(now: 10.1)
      #expect(due.count == remaining)
      let pass = partition(requested: due, budget: 12, now: 10.1)
      #expect(pass.allowedNow.count == 1)
      tracker.completeRetries(processIDs: pass.allowedNow, now: 10.1, unresolved: unresolved)
      for identity in identities where pass.stillDeferred.contains(identity.processID) {
        #expect(tracker.entries[identity]?.attempts == 0)
      }
    }
    #expect(tracker.dueProcessIDs(now: 10.1).isEmpty)
    #expect(tracker.entries.values.allSatisfy { $0.attempts == 1 })
  }

  private func partition(
    requested: Set<pid_t>,
    deferred: Set<pid_t> = [],
    eventPending: Set<pid_t> = [],
    latencies: [pid_t: Double] = [:],
    budget: Double = snapshotFreshReadBudgetMS,
    maxDeferredAge: TimeInterval = 0.5,
    deferredSince: TimeInterval? = nil,
    now: TimeInterval = 100
  ) -> (
    allowedNow: Set<pid_t>,
    stillDeferred: Set<pid_t>,
    deferredSince: TimeInterval?
  ) {
    budgetedFreshReadPartition(
      requestedProcessIDs: requested,
      deferredProcessIDs: deferred,
      eventPendingProcessIDs: eventPending,
      predictedLatencyMS: { latencies[$0] ?? 8.0 },
      budgetMS: budget,
      maximumDeferredAgeSeconds: maxDeferredAge,
      deferredSince: deferredSince,
      now: now
    )
  }

  // requested, deferred, event pending, latencies, budget, deferred since, now -> allowed, still deferred, since
  @Test(arguments: [
    // cheapest first within the budget
    ([1, 2, 3, 4], [], [], [1: 2, 2: 4, 3: 8, 4: 120], 12, nil, 100, [1, 2], [3, 4], 100),
    // at least one process per pass
    ([7], [], [], [7: 500], 12, nil, 100, [7], [], nil),
    // event-pending processes bypass the budget
    ([1, 2, 3], [], [3], [1: 2, 2: 4, 3: 200], 6, nil, 100, [1, 2, 3], [], nil),
    // the deferred age flush serves everything
    ([9], [4, 5], [], [4: 120, 5: 120, 9: 2], 12, 99.4, 100, [4, 5, 9], [], nil),
    ([], [], [], [:], 12, 90, 100, [], [], nil),
  ] as [([pid_t], [pid_t], [pid_t], [pid_t: Double], Double, TimeInterval?, TimeInterval, [pid_t], [pid_t], TimeInterval?)])
  func partitionsOnePass(requested: [pid_t], deferred: [pid_t], eventPending: [pid_t], latencies: [pid_t: Double],
    budget: Double, deferredSince: TimeInterval?, now: TimeInterval,
    allowed: [pid_t], stillDeferred: [pid_t], since: TimeInterval?) {
    let result = partition(requested: Set(requested), deferred: Set(deferred), eventPending: Set(eventPending),
      latencies: latencies, budget: budget, deferredSince: deferredSince, now: now)
    #expect(result.allowedNow == Set(allowed))
    #expect(result.stillDeferred == Set(stillDeferred))
    #expect(result.deferredSince == since)
  }
}
