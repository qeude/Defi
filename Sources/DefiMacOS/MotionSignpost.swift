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

  private static let spans = OSAllocatedUnfairLock(initialState: UInt64(0))

  /// An animation the render server runs for a known time. Each span has its own key, so
  /// overlapping spans each keep their own end.
  static func span(_ kind: StaticString, _ seconds: TimeInterval) {
    guard log.signpostsEnabled, seconds > 0 else { return }
    let key = spans.withLock { $0 &+= 1; return $0 }
    begin(kind, key)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { end(kind, key) }
  }
}
