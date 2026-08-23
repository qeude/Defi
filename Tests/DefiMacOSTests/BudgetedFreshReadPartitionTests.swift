import Darwin
import DefiModel
import Foundation
import Testing

@testable import DefiMacOS

struct BudgetedFreshReadPartitionTests {
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

  @Test
  func `Serves cheapest processes first within budget`() {
    let result = partition(
      requested: [1, 2, 3, 4],
      latencies: [1: 2, 2: 4, 3: 8, 4: 120],
      budget: 12
    )

    #expect(result.allowedNow == [1, 2])
    #expect(result.stillDeferred == [3, 4])
    #expect(result.deferredSince == 100)
  }

  @Test
  func `Always serves at least one process per pass`() {
    let result = partition(
      requested: [7],
      latencies: [7: 500],
      budget: 12
    )

    #expect(result.allowedNow == [7])
    #expect(result.stillDeferred.isEmpty)
    #expect(result.deferredSince == nil)
  }

  @Test
  func `Event pending processes bypass the budget`() {
    let result = partition(
      requested: [1, 2, 3],
      eventPending: [3],
      latencies: [1: 2, 2: 4, 3: 200],
      budget: 6
    )

    #expect(result.allowedNow == [1, 2, 3])
    #expect(result.stillDeferred.isEmpty)
  }

  @Test
  func `Deferred age flush serves everything and clears timestamp`() {
    let result = partition(
      requested: [9],
      deferred: [4, 5],
      latencies: [4: 120, 5: 120, 9: 2],
      deferredSince: 99.4,
      now: 100
    )

    #expect(result.allowedNow == [4, 5, 9])
    #expect(result.stillDeferred.isEmpty)
    #expect(result.deferredSince == nil)
  }

  @Test
  func `Empty pending clears deferral timestamp`() {
    let result = partition(
      requested: [],
      deferred: [],
      deferredSince: 90
    )

    #expect(result.allowedNow.isEmpty)
    #expect(result.stillDeferred.isEmpty)
    #expect(result.deferredSince == nil)
  }

  @Test
  func `Deferred processes keep their original deferral timestamp`() {
    let first = partition(
      requested: [1, 2],
      latencies: [1: 2, 2: 120],
      deferredSince: nil,
      now: 100
    )
    #expect(first.deferredSince == 100)

    // Progress guarantee: the single deferred process is always served on
    // the next pass even though it exceeds the budget alone.
    let second = partition(
      requested: [],
      deferred: first.stillDeferred,
      latencies: [2: 120],
      deferredSince: first.deferredSince,
      now: 100.2
    )
    #expect(second.deferredSince == nil)
  }
}
