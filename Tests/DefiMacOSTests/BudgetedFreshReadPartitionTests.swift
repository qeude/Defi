import DefiModel
import XCTest

@testable import DefiMacOS

final class BudgetedFreshReadPartitionTests: XCTestCase {
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

  func testServesCheapestProcessesFirstWithinBudget() {
    let result = partition(
      requested: [1, 2, 3, 4],
      latencies: [1: 2, 2: 4, 3: 8, 4: 120],
      budget: 12
    )

    XCTAssertEqual(result.allowedNow, [1, 2, 3])
    XCTAssertEqual(result.stillDeferred, [4])
    XCTAssertEqual(result.deferredSince, 100)
  }

  func testAlwaysServesAtLeastOneProcessPerPass() {
    let result = partition(
      requested: [7],
      latencies: [7: 500],
      budget: 12
    )

    XCTAssertEqual(result.allowedNow, [7])
    XCTAssertTrue(result.stillDeferred.isEmpty)
    XCTAssertNil(result.deferredSince)
  }

  func testEventPendingProcessesBypassTheBudget() {
    let result = partition(
      requested: [1, 2, 3],
      eventPending: [3],
      latencies: [1: 2, 2: 4, 3: 200],
      budget: 6
    )

    XCTAssertEqual(result.allowedNow, [1, 2, 3])
    XCTAssertTrue(result.stillDeferred.isEmpty)
  }

  func testDeferredAgeFlushServesEverythingAndClearsTimestamp() {
    let result = partition(
      requested: [9],
      deferred: [4, 5],
      latencies: [4: 120, 5: 120, 9: 2],
      deferredSince: 99.4,
      now: 100
    )

    XCTAssertEqual(result.allowedNow, [4, 5, 9])
    XCTAssertTrue(result.stillDeferred.isEmpty)
    XCTAssertNil(result.deferredSince)
  }

  func testEmptyPendingClearsDeferralTimestamp() {
    let result = partition(
      requested: [],
      deferred: [],
      deferredSince: 90
    )

    XCTAssertTrue(result.allowedNow.isEmpty)
    XCTAssertTrue(result.stillDeferred.isEmpty)
    XCTAssertNil(result.deferredSince)
  }

  func testDeferredProcessesKeepTheirOriginalDeferralTimestamp() {
    let first = partition(
      requested: [1, 2],
      latencies: [1: 2, 2: 120],
      deferredSince: nil,
      now: 100
    )
    XCTAssertEqual(first.deferredSince, 100)

    let second = partition(
      requested: [],
      deferred: first.stillDeferred,
      latencies: [2: 120],
      deferredSince: first.deferredSince,
      now: 100.2
    )
    XCTAssertEqual(second.deferredSince, 100)
  }
}
