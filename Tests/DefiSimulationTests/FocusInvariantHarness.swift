import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import DefiScenarioSupport
import Foundation
import Testing

@testable import DefiMacOS

/// One step of a generated scenario. Steps describe what the user and macOS do; Defi's
/// reaction is the code under test.
enum FocusStep: Hashable, ShrinkableStep {
  /// The user presses a bound column shortcut, toward the side that has a column.
  case press(preferRight: Bool, writerStepsDuringTap: Bool)
  /// The user types into the focused app: human input that is not a Defi command.
  case type
  /// The AX focus writer completes one Accessibility call.
  case writerStep
  /// The AX focus writer runs until it has nothing left to do.
  case writerRuns
  case setBusy(app: Int, busy: Bool, landLateWrites: Bool)
  case deliverFocusNotification
  /// The daemon tick that resubmits a queued focus.
  case tick
  /// The user focuses another window outside Defi: Command-Tab, the Dock or a click.
  case userFocuses(window: Int)
  /// The user revokes or grants Defi's Accessibility permission in System Settings.
  case setAccessibility(granted: Bool)
  /// The user focuses the workspace below or above (`<mod>-down` / `<mod>-up`).
  case switchWorkspace(down: Bool)
  /// The user moves the focused column to the workspace below or above and follows it
  /// (`<mod>-shift-down` / `<mod>-shift-up`).
  case moveColumnToWorkspace(down: Bool)

  var description: String {
    switch self {
    case .press(let right, let tap): "press(\(right ? "right" : "left")\(tap ? ", writer runs during tap" : ""))"
    case .type: "type"
    case .writerStep: "writerStep"
    case .writerRuns: "writerRuns"
    case .setBusy(let app, let busy, let late): "setBusy(app\(app), \(busy)\(late ? ", late writes land" : ""))"
    case .deliverFocusNotification: "deliverFocusNotification"
    case .tick: "tick"
    case .userFocuses(let window): "userFocuses(window \(window + 1))"
    case .setAccessibility(let granted): granted ? "grantAccessibility" : "revokeAccessibility"
    case .switchWorkspace(let down): "switchWorkspace(\(down ? "down" : "up"))"
    case .moveColumnToWorkspace(let down): "moveColumnToWorkspace(\(down ? "down" : "up"))"
    }
  }

  var simplifications: [FocusStep] {
    switch self {
    case .press(let right, true): [.press(preferRight: right, writerStepsDuringTap: false)]
    case .setBusy(let app, let busy, true): [.setBusy(app: app, busy: busy, landLateWrites: false)]
    default: []
    }
  }
}

struct FocusViolation: Equatable, CustomStringConvertible {
  let invariant: String
  let detail: String
  var description: String { "\(invariant): \(detail)" }
}

func generateFocusScenario(seed: UInt64) -> [FocusStep] {
  var random = SplitMix64(seed: seed)
  return (0..<(4 + random.below(20))).map { _ in
    switch random.below(100) {
    case 0..<30: .press(preferRight: random.chance(70), writerStepsDuringTap: random.chance(30))
    case 30..<42: .writerStep
    case 42..<55: .writerRuns
    case 55..<70: .setBusy(app: random.below(3), busy: random.chance(60), landLateWrites: random.chance(50))
    case 70..<80: .deliverFocusNotification
    case 80..<88: .tick
    case 88..<93: .userFocuses(window: random.below(4))
    case 93..<96: .setAccessibility(granted: random.chance(50))
    default: .type
    }
  }
}

/// The random scenario with workspace switches and column moves between workspaces, so
/// parking, workspace focus and vertical transitions run under the same timing faults.
func generateWorkspaceFocusScenario(seed: UInt64) -> [FocusStep] {
  var random = SplitMix64(seed: seed)
  return (0..<(4 + random.below(20))).map { _ in
    switch random.below(100) {
    case 0..<22: .press(preferRight: random.chance(70), writerStepsDuringTap: random.chance(30))
    case 22..<34: .switchWorkspace(down: random.chance(55))
    case 34..<42: .moveColumnToWorkspace(down: random.chance(60))
    case 42..<52: .writerStep
    case 52..<62: .writerRuns
    case 62..<74: .setBusy(app: random.below(3), busy: random.chance(60), landLateWrites: random.chance(50))
    case 74..<82: .deliverFocusNotification
    case 82..<90: .tick
    case 90..<95: .userFocuses(window: random.below(4))
    default: .type
    }
  }
}

/// PCT scheduling (probabilistic concurrency testing): the user and the AX writer get random
/// priorities that swap at `changePoints` random positions. Between two user actions the writer
/// runs to completion while it outranks the user and stays parked otherwise, so a scenario
/// explores one ordering with a few deliberate preemptions instead of uniform interleaving.
func generatePCTFocusScenario(seed: UInt64) -> [FocusStep] {
  var random = SplitMix64(seed: seed)
  let length = 4 + random.below(16)
  let changePoints = Set((0..<3).map { _ in random.below(length) })
  var writerOutranksUser = random.chance(50)
  var steps: [FocusStep] = []
  for index in 0..<length {
    if changePoints.contains(index) { writerOutranksUser.toggle() }
    let action: FocusStep = switch random.below(100) {
    case 0..<45: .press(preferRight: random.chance(70), writerStepsDuringTap: !writerOutranksUser && random.chance(50))
    case 45..<60: .setBusy(app: random.below(3), busy: random.chance(60), landLateWrites: random.chance(50))
    case 60..<72: .deliverFocusNotification
    case 72..<82: .tick
    case 82..<90: .userFocuses(window: random.below(4))
    default: .type
    }
    steps.append(action)
    steps.append(writerOutranksUser ? .writerRuns : .writerStep)
  }
  return steps
}

@NavigationActor
func runFocusScenario(_ steps: [FocusStep]) async -> (FocusViolation?, [String], Set<FakeMacBehavior>) {
  let world = try! await DaemonFocusWorld()
  defer { world.shutdown() }
  for step in steps {
    world.log.append("\(step)")
    await world.run(step)
    world.log.append("  " + world.stateLine)
    if let violation = world.checkStep() {
      return (violation, world.log, world.fake.behaviorsUsed)
    }
  }
  world.log.append("calm")
  await world.calm()
  if ProcessInfo.processInfo.environment["DEFI_SCENARIO_TRACE"] == "1" {
    world.log.append("daemon trace:\n\(world.platform.frameCoordinatorTrace)")
  }
  return (world.checkCalm(), world.log, world.fake.behaviorsUsed)
}

/// Suspects the harness reports on main, triaged until a desktop or CI run confirms them.
/// The busy-app classes are variants of the same rollback.
/// Key: invariant plus the catalog behaviors of the minimal case.
let knownFocusSuspects: [String: String] = [
  #"focus-visible ["accessibilityRevoked", "axCallTakesUpToItsTimeout", "focusNotificationArrivesLate"]"#:
    "suspect: frames refused while Accessibility was revoked are never rewritten once it is granted again; the simulated snapshot reports no target mismatches, so confirm once the real SnapshotEngine runs on the fake",
  #"focus-visible ["accessibilityRevoked", "axCallTakesUpToItsTimeout"]"#:
    "suspect: frames refused while Accessibility was revoked are never rewritten once it is granted again; the simulated snapshot reports no target mismatches, so confirm once the real SnapshotEngine runs on the fake",
  #"focus-visible ["accessibilityRevoked"]"#:
    "suspect: frames refused while Accessibility was revoked are never rewritten once it is granted again; the simulated snapshot reports no target mismatches, so confirm once the real SnapshotEngine runs on the fake",
  #"focus-visible ["accessibilityRevoked", "focusNotificationArrivesLate"]"#:
    "suspect: frames refused while Accessibility was revoked are never rewritten once it is granted again; the simulated snapshot reports no target mismatches, so confirm once the real SnapshotEngine runs on the fake",
  #"typing-target-kept ["axCallTakesUpToItsTimeout", "busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]"#: "suspect: a superseded focus write still in flight completes after newer typing and moves macOS away from the window the user typed into; confirm on the desktop",
  #"typing-target-kept ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate", "writerRunsDuringTapCallout"]"#: "suspect: a superseded focus write still in flight completes after newer typing and moves macOS away from the window the user typed into; confirm on the desktop",
  #"typing-target-kept ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate"]"#: "suspect: a superseded focus write still in flight completes after newer typing and moves macOS away from the window the user typed into; confirm on the desktop",
  #"native-converges ["focusNotificationArrivesLate"]"#:
    "suspect: column presses made while a Command-Tab notification is late queue a focus that never commits; Defi and macOS stay apart once calm (found by PCT, seed 230); confirm on the desktop",
  #"native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate", "writerRunsDuringTapCallout"]"#:
    "suspect: a Defi focus write still in flight lands after the user's Command-Tab and takes focus back; confirm on the desktop",
  #"native-converges ["axCallTakesUpToItsTimeout"]"#: "suspect: typing while a column focus is in flight rolls the selection back to a window macOS never focused (commandFocusCancellationFallback ignores native focus); reproduced on the real daemon with the simulated snapshot, confirm on the desktop",
  #"native-converges ["axCallTakesUpToItsTimeout", "busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]"#: "suspect: typing while a column focus is in flight rolls the selection back to a window macOS never focused (commandFocusCancellationFallback ignores native focus); reproduced on the real daemon with the simulated snapshot, confirm on the desktop",
  #"native-converges ["busyAppTimesOut", "focusNotificationArrivesLate", "timedOutWriteLandsLater"]"#: "suspect: typing while a column focus is in flight rolls the selection back to a window macOS never focused (commandFocusCancellationFallback ignores native focus); reproduced on the real daemon with the simulated snapshot, confirm on the desktop",
  #"native-converges ["axCallTakesUpToItsTimeout", "focusNotificationArrivesLate"]"#: "suspect: typing while a column focus is in flight rolls the selection back to a window macOS never focused (commandFocusCancellationFallback ignores native focus); reproduced on the real daemon with the simulated snapshot, confirm on the desktop",
]

/// The simulated desktop installs a process-wide virtual clock, so it runs only in the
/// isolated `make check` processes, never beside other suites that read real time.
@Suite(.serialized, .enabled(if: RealResourceGuard.isEnforced, "runs under make check (DEFI_ISOLATED=1)"))
struct FocusInvariantHarnessTests {
  /// Every ordering of three user and macOS actions after one press: the bounded exhaustive
  /// scheduler. About a minute, so only with DEFI_SCENARIO_DEEP=1.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DEFI_SCENARIO_DEEP"] == "1")) @NavigationActor
  func shortFocusOrderingsKeepInvariantsExhaustively() async {
    defer { try? FileManager.default.removeItem(at: DaemonFocusWorld.processDirectory) }
    let alphabet: [FocusStep] = [
      .press(preferRight: true, writerStepsDuringTap: false), .press(preferRight: false, writerStepsDuringTap: true),
      .type, .writerStep, .writerRuns, .deliverFocusNotification, .tick, .userFocuses(window: 0),
    ]
    var classes: [String: String] = [:]
    for a in alphabet { for b in alphabet { for c in alphabet {
      let steps: [FocusStep] = [.press(preferRight: true, writerStepsDuringTap: false), a, b, c]
      let (violation, _, behaviors) = await runFocusScenario(steps)
      guard let violation else { continue }
      let key = #"\#(violation.invariant) \#(behaviors.map(\.rawValue).sorted())"#
      guard knownFocusSuspects[key] == nil, classes[key] == nil else { continue }
      classes[key] = "\(violation) after \(steps)"
    }}}
    for report in classes.values.sorted() { Issue.record(Comment(rawValue: report)) }
  }

  @Test(arguments: ["random", "pct", "workspaces"]) @NavigationActor
  func randomFocusScenariosKeepFocusInvariants(scheduler: String) async {
    defer { try? FileManager.default.removeItem(at: DaemonFocusWorld.processDirectory) }
    let reports = await runScenarioCampaign(
      name: "focus/\(scheduler)",
      testFilter: "FocusInvariantHarnessTests",
      defaultRuns: ["pct": 160, "workspaces": 200][scheduler] ?? 400,
      knownSuspects: knownFocusSuspects,
      shrinkReplays: 2,
      generate: ["pct": generatePCTFocusScenario, "workspaces": generateWorkspaceFocusScenario][scheduler]
        ?? generateFocusScenario,
      run: { steps in
        let (violation, log, behaviors) = await runFocusScenario(steps)
        return ScenarioOutcome(
          invariant: violation?.invariant, message: violation?.detail ?? "",
          behaviors: Set(behaviors.map(\.rawValue)), log: log
        )
      }
    )
    for report in reports where !report.isKnownSuspect {
      Issue.record(Comment(rawValue: report.text))
    }
  }
}
