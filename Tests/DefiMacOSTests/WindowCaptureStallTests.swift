import CoreGraphics
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import DefiMacOS
import DefiRuntime

struct WindowCaptureStallTests {
  /// macOS can hold the WindowServer capture for minutes. Blocked on worker threads, such
  /// captures starved the threads that answer IPC and read windows.
  @Test func `Captures that never return leave status and window reads answering`() async {
    let release = DispatchSemaphore(value: 0), calls = Mutex(0), stalling = Mutex(true)
    let stalls = 4 * ProcessInfo.processInfo.activeProcessorCount
    let capture = ribbonProxyBoundedCapture(deadline: 0.1) { _ in
      calls.withLock { $0 += 1 }
      if stalling.withLock({ $0 }) { release.wait() }
      return []
    }
    // As many at once as a landing, a window opening and the desktop refresh can start.
    for id in 0..<stalls {
      Task.detached(priority: .userInitiated) { #expect(capture([CGWindowID(id)]) == nil) }
    }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(capture([99]) == nil)
    let started = calls.withLock { $0 }
    #expect(started < stalls, "No capture starts while one is stalled")

    // `status` goes through a dispatch worker to the navigation queue; window reads use
    // dispatch workers, and the ribbon refresh uses Swift tasks.
    #expect(statusAnswers(within: 2), "IPC requests time out after two seconds")
    let task = Task.detached(priority: .userInitiated) { true }
    #expect(await task.value)

    stalling.withLock { $0 = false }
    for _ in 0..<started { release.signal() }
    var resumed: [CGImage]?
    for _ in 0..<100 where resumed == nil {
      try? await Task.sleep(for: .milliseconds(20))
      resumed = capture([100])
    }
    #expect(resumed == [], "Captures resume once the stalled ones return")
  }
}

private func statusAnswers(within seconds: Double) -> Bool {
  let answered = DispatchSemaphore(value: 0)
  DispatchQueue.global(qos: .userInitiated).async {
    NavigationActor.shared.queue.sync {}
    answered.signal()
  }
  return answered.wait(timeout: .now() + seconds) == .success
}
