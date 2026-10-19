import Darwin
import Foundation
import Synchronization
import Testing
@testable import DefiMacOS

struct FrameAnimationDriverPerformanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1"))
  func timerDispatchPerformance() throws {
    let queue = DispatchQueue(label: "test.animation-timer-performance")
    let callbacks = Mutex(0)
    let completed = DispatchSemaphore(value: 0)
    let interval = 1.0 / 120
    var cpuBefore = rusage()
    getrusage(RUSAGE_SELF, &cpuBefore)
    let start = ProcessInfo.processInfo.systemUptime
    let driver = FrameAnimationDriver(interval: interval, refreshInterval: interval,
                                     displayIDs: [], queue: queue) { driver in
      dispatchPrecondition(condition: .onQueue(queue))
      let steps = callbacks.withLock { $0 += 1; return $0 }
      if steps == 32 {
        driver.stop()
        completed.signal()
      }
      return true
    }
    defer { driver.stop() }
    let finished = completed.wait(timeout: .now() + 5)
    driver.stop()
    queue.sync {}
    let durationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
    var cpuAfter = rusage()
    getrusage(RUSAGE_SELF, &cpuAfter)
    let cpuMS = Double(cpuAfter.ru_utime.tv_sec - cpuBefore.ru_utime.tv_sec
      + cpuAfter.ru_stime.tv_sec - cpuBefore.ru_stime.tv_sec) * 1000
      + Double(cpuAfter.ru_utime.tv_usec - cpuBefore.ru_utime.tv_usec
        + cpuAfter.ru_stime.tv_usec - cpuBefore.ru_stime.tv_usec) / 1000
    let diagnostics = Dictionary(uniqueKeysWithValues: driver.diagnosticSummary.split(separator: " ").compactMap {
      field -> (String, Int)? in
      let parts = field.split(separator: "=", maxSplits: 1)
      guard parts.count == 2, let value = Int(parts[1]) else { return nil }
      return (String(parts[0]), value)
    })
    let steps = try #require(diagnostics["timerSteps"])
    let queueSubmissions = try #require(diagnostics["queueTicks"])
    let callbackSteps = callbacks.withLock { $0 }
    let errors = (finished == .success ? 0 : 1) + (steps == 32 ? 0 : 1)
      + (callbackSteps == 32 ? 0 : 1)
    #expect(finished == .success)
    #expect(steps == 32)
    #expect(callbackSteps == 32)
    #expect(errors == 0)
    let record: [String: Any] = ["case": "timer-dispatch", "operations": steps, "errors": errors,
      "output": ["steps": steps],
      "metrics": ["queue_submissions": Double(queueSubmissions), "elapsed_ms": durationMS,
        "cpu_ms": cpuMS, "voluntary_context_switches": Double(cpuAfter.ru_nvcsw - cpuBefore.ru_nvcsw),
        "involuntary_context_switches": Double(cpuAfter.ru_nivcsw - cpuBefore.ru_nivcsw)]]
    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
  }
}
