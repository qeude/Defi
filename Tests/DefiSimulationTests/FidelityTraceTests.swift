import ApplicationServices
import DefiModel
import DefiRuntime
import Foundation
import Testing

@testable import DefiMacOS

/// Replays the desktop fidelity scenarios (DesktopE2ETests.testFocusTraceForSimulationFidelity)
/// on the simulated macOS and compares the Accessibility focus calls with the real trace.
/// Tolerances: the same calls, targets and results in the same order; each real AX call ends
/// within the 50 ms focus write timeout (AXFocusWriterExecution) plus 25 ms of scheduling slack,
/// which is what the catalog's axCallTakesUpToItsTimeout assumes.
@NavigationActor
func simulatedFidelityTrace() async -> [String: [AXCall]] {
  let appA: pid_t = -91, appB: pid_t = -92
  let windowA = WindowID(rawValue: 1), windowB = WindowID(rawValue: 2)
  let fake = FakeMacOS(
    space: FakeMacOS.spaceForNextWorld(), owners: [windowA: appA, windowB: appB],
    focused: [appA: windowA, appB: windowB], frontmost: appB
  )
  fake.gate.openPermanently()
  let log = AXCallLog { element in
    if CFEqual(element, fake.windowElement(windowA)) { return "window-a" }
    if CFEqual(element, fake.windowElement(windowB)) { return "window-b" }
    if CFEqual(element, fake.applicationElement(appA)) { return "app-a" }
    if CFEqual(element, fake.applicationElement(appB)) { return "app-b" }
    return "other"
  }
  let platform = MacOSPlatform(frameCoordinator: nil, focusOperations: fake.operations.recording(into: log))
  for (window, app) in [(windowA, appA), (windowB, appB)] {
    platform.elements[window] = fake.windowElement(window)
    platform.processIDs[window] = app
    platform.applications[app] = fake.applicationElement(app)
    platform.applicationWindowCounts[app] = 1
  }
  platform.lastNativeFocusedWindowID = windowB
  func waitIdle() async {
    for _ in 0..<500 where platform.hasPendingFocusWrite {
      try? await Task.sleep(for: .milliseconds(2))
    }
  }
  var trace: [String: [AXCall]] = [:]
  for scenario in ["focus-other-app", "focus-back", "rapid-burst"] {
    log.reset()
    switch scenario {
    case "focus-other-app": platform.focus(windowA)
    case "focus-back": platform.focus(windowB)
    default: for id in [windowA, windowB, windowA, windowB] { platform.focus(id) }
    }
    await waitIdle()
    platform.lastNativeFocusedWindowID = fake.keyWindow
    trace[scenario] = log.entries
  }
  return trace
}

struct FidelityTraceTests {
  /// DEFI_AX_TRACE_IN names the real trace a desktop run wrote (CI artifact).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_AX_TRACE_IN"] != nil)) @NavigationActor
  func simulatedFocusCallsMatchTheRealDesktop() async throws {
    let path = ProcessInfo.processInfo.environment["DEFI_AX_TRACE_IN"]!
    let real = try JSONDecoder().decode([String: [AXCall]].self, from: Data(contentsOf: URL(filePath: path)))
    let simulated = await simulatedFidelityTrace()
    for (scenario, realCalls) in real.sorted(by: { $0.key < $1.key }) {
      let calls = simulated[scenario] ?? []
      let shape: (AXCall) -> String = { "\($0.operation)(\($0.target)) -> \($0.result)" }
      // How many superseded requests of a burst still run depends on thread timing, on macOS and
      // in the simulation alike, so only the final request's calls are compared.
      let finalRequest: ([AXCall]) -> [String] = { log in
        let last = log.lastIndex { $0.operation == "targetIsFocused" } ?? 0
        return log[last...].map(shape)
      }
      #expect(finalRequest(calls) == finalRequest(realCalls), "\(scenario): simulated calls differ from the real desktop")
      for call in realCalls where call.operation != "activateApplication" && call.milliseconds > 75 {
        Issue.record("\(scenario): real \(shape(call)) took \(call.milliseconds) ms, beyond the catalog bound")
      }
    }
  }

  /// Without a real trace, the simulated side still runs and produces every scenario.
  @Test @NavigationActor
  func simulatedTraceCoversEveryScenario() async {
    let trace = await simulatedFidelityTrace()
    #expect(Set(trace.keys) == ["focus-other-app", "focus-back", "rapid-burst"])
    #expect(trace.values.allSatisfy { !$0.isEmpty })
  }

  /// DEFI_FRAME_TRACE_IN names the real frame trace (DesktopE2ETests.testFrameTraceForSimulationFidelity).
  /// Tolerance: the simulated window settles within 2 pt of where macOS left the real one.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_FRAME_TRACE_IN"] != nil))
  func simulatedPositionWritesSettleWhereTheRealDesktopLeavesWindows() throws {
    let path = ProcessInfo.processInfo.environment["DEFI_FRAME_TRACE_IN"]!
    let real = try JSONDecoder().decode([String: FrameWriteTrace].self, from: Data(contentsOf: URL(filePath: path)))
    #expect(!real.isEmpty)
    let window = WindowID(rawValue: 1)
    for (scenario, trace) in real.sorted(by: { $0.key < $1.key }) {
      let fake = FakeMacOS(
        space: FakeMacOS.spaceForNextWorld(), owners: [window: -91], focused: [-91: window], frontmost: -91,
        displays: [trace.display]
      )
      fake.setFrame(trace.start, of: window)
      _ = fake.moveWindow(fake.windowElement(window), to: CGPoint(x: trace.target.x, y: trace.target.y))
      let settled = try #require(fake.frame(of: window))
      #expect(
        abs(settled.x - trace.settled.x) <= 2 && abs(settled.y - trace.settled.y) <= 2,
        "\(scenario): simulated window settles at \(settled), macOS left it at \(trace.settled)"
      )
    }
  }
}
