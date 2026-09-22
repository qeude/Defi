import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Foundation
import Synchronization
import Testing

private struct ReplayResult: Sendable {
  let selected: WindowID?
  let frames: [FrameAssignment]
  let onMainThread: Bool
  let milliseconds: Double
}

struct NavigationIsolationTests {
  /// A stalled AppKit executor must not delay command reduction or placement.
  /// Semaphore handshakes make this a dependency test, not a speed threshold.
  @Test @MainActor
  func commandsAndPlacementProgressWhileMainActorIsBlocked() async throws {
    let monitor = MonitorID(rawValue: 1)
    let viewport = Rect(x: 0, y: 0, width: 1_200, height: 800)
    var initial = RuntimeState(config: Config())
    initial.attachMonitor(monitor)
    for id in 1...3 {
      try discoverWindow(
        Window(id: WindowID(rawValue: UInt64(id)), appID: "fixture", title: "",
          frame: Rect(x: 0, y: 0, width: 600, height: 800), monitorID: monitor),
        decision: RuleDecision(), state: &initial
      )
    }
    initial.monitors[0].workspaces[0].columns.sort { $0.windows[0].rawValue < $1.windows[0].rawValue }
    initial.monitors[0].workspaces[0].focusedColumn = 0
    let initialState = initial
    let finished = DispatchSemaphore(value: 0)
    let result = Mutex<ReplayResult?>(nil)
    let started = ProcessInfo.processInfo.systemUptime
    NavigationActor.enqueue {
      var state = initialState
      do {
        for raw in ["focus-column right", "focus-column right", "focus-column left"] {
          try reduce(parseCommand(raw), on: monitor, state: &state, viewports: [monitor: viewport])
        }
        let workspace = state.monitors[0].workspaces[0]
        let frames = computeLayout(workspace: workspace, viewport: viewport,
          windows: Array(state.windows.values), settings: state.layout)
        result.withLock {
          $0 = ReplayResult(selected: state.selectedWindowID(on: monitor), frames: frames,
            onMainThread: Thread.isMainThread,
            milliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000)
        }
      } catch {
        Issue.record("Replay failed: \(error)")
      }
      finished.signal()
    }
    #expect(blockMain(until: finished, seconds: 2) == .success,
      "Command handling must complete before MainActor is released")
    let actual = try #require(result.withLock { $0 })
    #expect(!actual.onMainThread)
    #expect(actual.selected == WindowID(rawValue: 2))
    #expect(actual.frames.count == 3)
    #expect(actual.frames.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })

    // The old main-queue routing necessarily pays the entire injected stall.
    let reference = Mutex(0.0)
    let referenceFinished = DispatchSemaphore(value: 0)
    let referenceStarted = ProcessInfo.processInfo.systemUptime
    DispatchQueue.main.async {
      reference.withLock { $0 = (ProcessInfo.processInfo.systemUptime - referenceStarted) * 1_000 }
      referenceFinished.signal()
    }
    #expect(blockMain(until: referenceFinished, seconds: 0.1) == .timedOut)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    print(String(format: "navigation isolation: main-queue reference %.2f ms; navigation + placement %.2f ms",
      reference.withLock { $0 }, actual.milliseconds))
  }

  @Test
  func callbackMessagesPreserveArrivalOrder() async {
    let received = Mutex<[Int]>([])
    await withCheckedContinuation { continuation in
      for sequence in 0..<500 {
        NavigationActor.enqueue {
          received.withLock { $0.append(sequence) }
        }
      }
      NavigationActor.enqueue { continuation.resume() }
    }
    #expect(received.withLock { $0 } == Array(0..<500))
  }
}

@MainActor
private func blockMain(until semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
  semaphore.wait(timeout: .now() + seconds)
}
