import Foundation
import Testing
@testable import DefiMacOS

struct FallbackPollingPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1"))
  func scopedFallbackPolling() throws {
    var deadlines: [pid_t: TimeInterval] = [:]
    var nextGlobal = 0.0
    var coveredReads = 0
    var fallbackReads = 0
    var forcedRecovery = false
    let interval = windowListRefreshInterval(hasPendingShortRetry: false,
      reliableTopologyObservation: false, hasScopedTopologyFallback: true)
    for index in 0..<301 {
      let now = Double(index) / 100
      let global = now + 0.000001 >= nextGlobal
      if global { coveredReads += 8; nextGlobal = now + interval }
      let due = fallbackWindowRefreshProcessIDs(uncovered: [41], incompatible: [],
        eventProcessIDs: index == 150 ? [41] : [], force: global, now: now, deadlines: &deadlines)
      fallbackReads += due.count
      if index == 150 { forcedRecovery = due.contains(41) }
    }
    #expect(forcedRecovery)
    let record: [String: Any] = ["case": "fallback-polling", "operations": 301, "errors": forcedRecovery ? 0 : 1,
      "output": ["forced_recovery": forcedRecovery ? 1 : 0],
      "metrics": ["covered_read_requests": coveredReads, "fallback_read_requests": fallbackReads]]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
  }
}
