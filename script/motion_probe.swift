import AppKit
import CoreGraphics
import Darwin
import Foundation

// Read-only WindowServer sampler for script/motion_probe.py. Timestamps are
// ProcessInfo.systemUptime, the clock `defi trace` uses.
//   motion-probe sample <daemon-pid> <seconds> <interval-ms>
//     JSONL: a start line (uptime + display rects), one line per change of the daemon's
//     windows or the on-screen layer-0 app windows, and an end line with interval p50/p95,
//     tick count, sampler errors and daemon CPU seconds. SIGTERM/SIGINT end the run early.
//   motion-probe bundles <pid>...   prints {"<pid>": "<bundle id>"}

nonisolated(unsafe) var stopRequested: Int32 = 0

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

func daemonCPUSeconds(_ daemon: Int32) -> Double {
  var usage = rusage_info_current()
  let status = withUnsafeMutablePointer(to: &usage) {
    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
      proc_pid_rusage(daemon, RUSAGE_INFO_CURRENT, $0)
    }
  }
  var base = mach_timebase_info_data_t()
  mach_timebase_info(&base)
  guard status == 0 else { return 0 }
  return Double(usage.ri_user_time + usage.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e9
}

func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
  sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
}

func sample(daemon: Int32, seconds: Double, intervalMS: Double) {
  signal(SIGTERM) { _ in stopRequested = 1 }
  signal(SIGINT) { _ in stopRequested = 1 }
  var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
  var displayCount: UInt32 = 0
  CGGetActiveDisplayList(16, &displayIDs, &displayCount)
  let displays = displayIDs.prefix(Int(displayCount)).map { id -> [Int] in
    let r = CGDisplayBounds(id)
    return [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
  }
  let start = uptime()
  let cpuStart = daemonCPUSeconds(daemon)
  print("{\"start\":\(String(format: "%.6f", start)),\"displays\":\(displays)}")
  var ticks = 0, errors = 0
  var gaps: [Double] = []
  var previous = ""
  var lastTick = start
  var next = start
  while uptime() - start < seconds, stopRequested == 0 {
    let now = uptime()
    if ticks > 0 { gaps.append((now - lastTick) * 1000) }
    lastTick = now
    ticks += 1
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
      errors += 1
      continue
    }
    // A slow WindowServer query means the compositor itself stalled, not Defi.
    let queryMS = (uptime() - now) * 1000
    if queryMS > 30 { print(String(format: "{\"stall\":%.6f,\"ms\":%.1f}", now, queryMS)) }
    var apps: [[Int]] = []
    var edges: [[Int]] = []
    for info in list {
      let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
      let layer = info[kCGWindowLayer as String] as? Int ?? -1
      let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
      guard alpha > 0.01, pid == daemon || layer == 0 else { continue }
      let id = info[kCGWindowNumber as String] as? Int ?? 0
      let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
      let frame = ["X", "Y", "Width", "Height"].map { Int((bounds[$0] ?? 0).rounded()) }
      if pid == daemon {
        edges.append([id, layer] + frame)
      } else if frame[2] >= 50, frame[3] >= 50 {
        apps.append([id, Int(pid)] + frame)
      }
    }
    apps.sort { $0[0] < $1[0] }  // list order varies between reads; sort so only real changes emit
    edges.sort { $0[0] < $1[0] }
    let body = "\"apps\":\(apps),\"edges\":\(edges)"
    if body != previous {
      print("{\"t\":\(String(format: "%.6f", now)),\(body)}")
      previous = body
    }
    next += intervalMS / 1000
    let wait = next - uptime()
    if wait > 0 { usleep(UInt32(wait * 1e6)) } else { next = uptime() }
  }
  gaps.sort()
  print(
    String(
      format: "{\"end\":true,\"t\":%.6f,\"ticks\":%d,\"errors\":%d,\"interval_ms_p50\":%.2f,\"interval_ms_p95\":%.2f,\"interval_ms_max\":%.2f,\"cpu_s\":%.4f}",
      uptime(), ticks, errors, percentile(gaps, 0.5), percentile(gaps, 0.95), gaps.last ?? 0,
      daemonCPUSeconds(daemon) - cpuStart))
}

let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "sample", let daemon = Int32(arguments[2]),
  let seconds = Double(arguments[3]), let intervalMS = Double(arguments[4])
{
  sample(daemon: daemon, seconds: seconds, intervalMS: intervalMS)
} else if arguments.count >= 2, arguments[1] == "bundles" {
  var names: [String: String] = [:]
  for argument in arguments.dropFirst(2) {
    if let pid = Int32(argument),
      let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    {
      names[argument] = id
    }
  }
  let data = try JSONSerialization.data(withJSONObject: names, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
} else {
  FileHandle.standardError.write(
    Data("usage: motion-probe sample <pid> <seconds> <interval-ms> | bundles <pid>...\n".utf8))
  exit(2)
}
