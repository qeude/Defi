import ApplicationServices
import Darwin
import DefiConfig
import DefiModel
import DefiRuntime
import Testing
@testable import DefiMacOS

struct IncrementalDiscoveryPerformanceTests {
  @MainActor @Test
  func incrementalDiscoveryPerformance() {
    let cases = [
      (name: "zero-delay-single-cached-window", oneCachedWindow: true, targeted: true, delay: 0.0, operations: 2000),
      (name: "incremental-one-window", oneCachedWindow: false, targeted: true, delay: 0.004, operations: 10),
      (name: "incremental-four-pids", oneCachedWindow: false, targeted: false, delay: 0.004, operations: 10)
    ]
    for workload in cases {
      let platform = NavigationActor.shared.queue.sync {
        NavigationActor.assumeIsolated { MacOSPlatform() }
      }
      let engine = platform.snapshotEngine
      let fixture = DiscoveryReadFixture()
      fixture.failsProcess = nil
      fixture.revealsNewWindow = false
      fixture.state.withLock { $0.delay = workload.delay }
      var windows: [Window] = []
      var elements: [WindowID: AXUIElement] = [:]
      let pids: [pid_t] = workload.oneCachedWindow ? [41] : [41, 42, 43, 44]
      for pid in pids {
        for index in 0..<(workload.oneCachedWindow ? 1 : 4) {
          let id = WindowID(rawValue: UInt64(Int(pid) * 100 + index))
          let element = AXUIElementCreateApplication(-60000 - pid * 100 - Int32(index))
          let window = Window(id: id, appID: "measurement", title: "window-\(id.rawValue)",
            frame: Rect(x: Double(index * 410), y: 20, width: 400, height: 300),
            role: kAXWindowRole, subrole: kAXStandardWindowSubrole, processID: pid,
            floating: true, floatingOrigin: .configured)
          windows.append(window)
          elements[id] = element
          fixture.windowLists[pid, default: []].append(element)
          fixture.windowsByHash[CFHash(element)] = window
        }
      }
      let cg = windows.map { CGWindowRecord(id: CGWindowID($0.id.rawValue), processID: $0.processID!,
        layer: 0, title: $0.title, frame: $0.frame, isOnscreen: true) }
      var access = fixture.access()
      access.snapshotCGWindows = { cg }
      access.nativeFocus = { _ in nil }
      engine.discoveryMeasurementAccess = access
      engine.applications = Dictionary(uniqueKeysWithValues: pids.map { ($0, AXUIElementCreateApplication(-50000 - $0)) })
      engine.applicationIDsByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, "measurement") })
      engine.enhancedUIByProcess = Dictionary(uniqueKeysWithValues: pids.map { ($0, false) })
      engine.elements = elements
      engine.processIDs = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0.processID!) })
      engine.lastSnapshotWindows = windows
      engine.lastApplicationWindowElements = fixture.windowLists
      engine.hasCompletedWindowSnapshot = true
      engine.overviewPresentationActive = true
      engine.publishCGWindowInventory(CGWindowInventory(records: cg, generation: 0,
        capturedAt: ProcessInfo.processInfo.systemUptime))
      let config = Config(rules: [Rule(appID: "measurement", floating: true)])
      let expectedIDs: [UInt64] = workload.oneCachedWindow ? [4100] :
        [4100, 4101, 4102, 4103, 4200, 4201, 4202, 4203, 4300, 4301, 4302, 4303, 4400, 4401, 4402, 4403]
      let expectedFrames = workload.oneCachedWindow ? [Rect(x: 0, y: 20, width: 400, height: 300)] :
        Array(repeating: [Rect(x: 0, y: 20, width: 400, height: 300), Rect(x: 410, y: 20, width: 400, height: 300),
          Rect(x: 820, y: 20, width: 400, height: 300), Rect(x: 1230, y: 20, width: 400, height: 300)], count: 4).flatMap { $0 }
      let expectedPIDs: [pid_t] = workload.oneCachedWindow ? [41] :
        [41, 41, 41, 41, 42, 42, 42, 42, 43, 43, 43, 43, 44, 44, 44, 44]
      let expectedTitles = workload.oneCachedWindow ? ["window-4100"] :
        ["window-4100", "window-4101", "window-4102", "window-4103", "window-4200", "window-4201", "window-4202", "window-4203",
         "window-4300", "window-4301", "window-4302", "window-4303", "window-4400", "window-4401", "window-4402", "window-4403"]
      var cpuBefore = rusage()
      getrusage(RUSAGE_SELF, &cpuBefore)
      let start = ProcessInfo.processInfo.systemUptime
      var completed = 0
      var correct = 0
      var errors = 0
      for _ in 0..<workload.operations {
        if workload.targeted { engine.recordObservation(.frame, processID: 41, windowID: WindowID(rawValue: 4100)) }
        else { for pid: pid_t in 41...44 { engine.recordObservation(.frame, processID: pid) } }
        let snapshot = engine.snapshot(config: config, forceFullWindowRefresh: false,
          forceWindowListRefresh: false, forceApplicationInventoryRefresh: false)
        let observed = snapshot.windows.sorted { $0.id.rawValue < $1.id.rawValue }
        completed += 1
        if observed.map({ $0.id.rawValue }) == expectedIDs, observed.map(\.frame) == expectedFrames,
          observed.map({ $0.processID ?? -1 }) == expectedPIDs, observed.map(\.title) == expectedTitles,
          observed.allSatisfy({ $0.appID == "measurement" && $0.floating && $0.floatingOrigin == .configured
            && $0.role == kAXWindowRole && $0.subrole == kAXStandardWindowSubrole }) {
          correct += 1
        } else { errors += 1 }
      }
      let durationMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
      var cpuAfter = rusage()
      getrusage(RUSAGE_SELF, &cpuAfter)
      let cpuMS = Double(cpuAfter.ru_utime.tv_sec - cpuBefore.ru_utime.tv_sec
        + cpuAfter.ru_stime.tv_sec - cpuBefore.ru_stime.tv_sec) * 1000
        + Double(cpuAfter.ru_utime.tv_usec - cpuBefore.ru_utime.tv_usec
          + cpuAfter.ru_stime.tv_usec - cpuBefore.ru_stime.tv_usec) / 1000
      let state = fixture.state.withLock { $0 }
      #expect(completed == workload.operations)
      #expect(correct == workload.operations)
      #expect(errors == 0)
      #expect(state.attributeCalls == (workload.targeted ? workload.operations : 160))
      #expect(state.listCalls.values.reduce(0, +) == 0)
      #expect(state.relationshipCalls == 0)
      guard ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1" else { continue }
      let record: [String: Any] = ["case": workload.name, "operations": completed, "errors": errors,
        "output": ["correct_snapshots": correct, "windows": expectedIDs.count],
        "literal_windows": zip(zip(expectedIDs, expectedFrames), zip(expectedPIDs, expectedTitles)).map { idsAndFrame, pidAndTitle in
          ["id": idsAndFrame.0, "x": idsAndFrame.1.x, "y": idsAndFrame.1.y,
           "width": idsAndFrame.1.width, "height": idsAndFrame.1.height, "pid": pidAndTitle.0,
           "title": pidAndTitle.1, "app_id": "measurement", "floating": true, "floating_origin": "configured"] as [String: Any]
        },
        "metrics": ["attribute_reads": Double(state.attributeCalls),
          "list_reads": Double(state.listCalls.values.reduce(0, +)), "relationship_reads": Double(state.relationshipCalls),
          "maximum_concurrent_reads": Double(state.maximumActive), "snapshot_duration_ms": durationMS / Double(completed),
          "cpu_ms": cpuMS, "voluntary_context_switches": Double(cpuAfter.ru_nvcsw - cpuBefore.ru_nvcsw),
          "involuntary_context_switches": Double(cpuAfter.ru_nivcsw - cpuBefore.ru_nivcsw)]]
      let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
      print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
    }
  }
}
