import CoreGraphics
import Darwin
import Foundation

// Read-only WindowServer sampler. Prints one JSON line whenever the visible app-window
// or daemon-edge geometry changes, then a final line with sample count and daemon CPU.
// usage: border-sync-probe <daemon-pid> <seconds> <interval-ms>

let arguments = CommandLine.arguments
guard arguments.count == 4, let daemon = Int32(arguments[1]), let seconds = Double(arguments[2]),
  let intervalMS = Double(arguments[3])
else {
  FileHandle.standardError.write(Data("usage: border-sync-probe <daemon-pid> <seconds> <interval-ms>\n".utf8))
  exit(2)
}

func daemonCPUSeconds() -> Double {
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

func rect(_ info: [String: Any]) -> [Int] {
  let bounds = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
  return ["X", "Y", "Width", "Height"].map { Int((bounds[$0] ?? 0).rounded()) }
}

let start = Date()
let cpuStart = daemonCPUSeconds()
var samples = 0
var previous = ""
while Date().timeIntervalSince(start) < seconds {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  var apps: [[Int]] = []
  var edges: [[Int]] = []
  for info in list {
    let pid = info[kCGWindowOwnerPID as String] as? Int32 ?? 0
    let layer = info[kCGWindowLayer as String] as? Int ?? -1
    let id = info[kCGWindowNumber as String] as? Int ?? 0
    let frame = rect(info)
    if pid == daemon {
      if layer == 0 || layer == 3 { edges.append([id, layer] + frame) }
    } else if layer == 0, frame[2] >= 50, frame[3] >= 50 {
      apps.append([id] + frame)
    }
  }
  let line = "{\"apps\":\(apps),\"edges\":\(edges)"
  if line != previous {
    print("\(line),\"t\":\(Date().timeIntervalSince(start)),\"n\":\(samples)}")
    previous = line
  }
  samples += 1
  usleep(UInt32(intervalMS * 1000))
}
print(String(format: "{\"end\":true,\"t\":%.4f,\"n\":%d,\"cpu_s\":%.4f}",
  Date().timeIntervalSince(start), samples, daemonCPUSeconds() - cpuStart))
