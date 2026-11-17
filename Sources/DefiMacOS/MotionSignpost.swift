import Foundation
import os

/// Brackets every animation in Points of Interest so `script/fluidity_probe.py` judges render
/// gaps only while something moves; a still screen renders nothing and is not a dropped frame.
enum MotionSignpost {
  private static let log = OSLog(subsystem: "com.qeude.defi", category: .pointsOfInterest)

  static func begin(_ kind: StaticString, _ key: UInt64 = 0) {
    guard log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: "motion", "begin %{public}s %llu", String(describing: kind), key)
  }

  static func end(_ kind: StaticString, _ key: UInt64 = 0) {
    guard log.signpostsEnabled else { return }
    os_signpost(.event, log: log, name: "motion", "end %{public}s %llu", String(describing: kind), key)
  }

  /// An animation the render server runs for a known time.
  static func span(_ kind: StaticString, _ seconds: TimeInterval) {
    guard log.signpostsEnabled, seconds > 0 else { return }
    begin(kind, 1)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { end(kind, 1) }
  }
}
