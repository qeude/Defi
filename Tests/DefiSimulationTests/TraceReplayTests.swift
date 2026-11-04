import DefiModel
import DefiRuntime
import DefiScenarioSupport
import Foundation
import Testing

/// Turns a `defi trace` into simulated-desktop steps. The trace records the column shortcuts the
/// user pressed; each press is followed by the writer and a tick, as on a calm desktop.
// shortcut: replays column focus presses only; extend the mapping as the simulated desktop
// learns more trace events (activations, window lifecycle, mouse).
func focusSteps(fromTrace trace: String) -> [FocusStep] {
  trace.split(separator: "\n").flatMap { line -> [FocusStep] in
    guard line.contains(" hotkey command=focus-column ") else { return [] }
    let right = line.contains("command=focus-column right")
    guard right || line.contains("command=focus-column left") else { return [] }
    return [.press(preferRight: right, writerStepsDuringTap: false), .writerRuns, .tick]
  }
}

struct TraceReplayTests {
  @Test func traceColumnPressesBecomeSteps() {
    let trace = """
      163068.454669 hotkey command=focus-column right sourcePID=89434
      163068.454747 command-start cg=1 command=focus-column right source=hotkey validationMs=0.06
      163068.455243 hotkey command=focus-column left sourcePID=89434
      163068.455300 hotkey command=workspace 2 sourcePID=89434
      """
    #expect(focusSteps(fromTrace: trace) == [
      .press(preferRight: true, writerStepsDuringTap: false), .writerRuns, .tick,
      .press(preferRight: false, writerStepsDuringTap: false), .writerRuns, .tick,
    ])
  }

  /// DEFI_REPLAY_TRACE=<file> replays a saved `defi trace` on the simulated desktop.
  @Test(.enabled(if: RealResourceGuard.isEnforced && ProcessInfo.processInfo.environment["DEFI_REPLAY_TRACE"] != nil)) @NavigationActor
  func replaySavedTrace() async throws {
    let path = ProcessInfo.processInfo.environment["DEFI_REPLAY_TRACE"]!
    let steps = focusSteps(fromTrace: try String(contentsOfFile: path, encoding: .utf8))
    let (violation, log, behaviors) = await runFocusScenario(steps)
    print(log.joined(separator: "\n"))
    if let violation {
      Issue.record("\(violation) with catalog behaviors \(behaviors.map(\.rawValue).sorted())")
    }
  }
}
