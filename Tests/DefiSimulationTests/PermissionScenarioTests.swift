import DefiModel
import DefiScenarioSupport
import Foundation
import Testing

@testable import DefiMacOS

/// What macOS does with the Accessibility grant while Defi waits for it.
enum PermissionStep: ShrinkableStep, Equatable {
  case grant
  case revoke
  /// The undocumented distributed notification macOS posts when the grant list changes.
  case notify
  /// The monitor's one-second poll fires.
  case poll

  var description: String {
    switch self {
    case .grant: "grant"
    case .revoke: "revoke"
    case .notify: "notify"
    case .poll: "poll"
    }
  }
}

/// Runs the real AccessibilityPermissionMonitor against a scripted grant. Rules (AGENTS.md,
/// Screen Recording and Runtime sections): window management starts exactly once, only after
/// the grant is confirmed through the public API, and the user is prompted at most once.
@MainActor
func runPermissionScenario(_ steps: [PermissionStep]) -> ScenarioOutcome {
  var trusted = false
  var prompts = 0
  var granted = 0
  var everTrustedBeforeGrant = false
  let center = NotificationCenter()
  let monitor = AccessibilityPermissionMonitor(center: center) { prompt in
    if prompt { prompts += 1 }
    return trusted
  }
  monitor.start { granted += 1 }
  var log = ["start"]
  for step in steps {
    log.append(step.description)
    switch step {
    case .grant: trusted = true
    case .revoke: trusted = false
    case .notify: center.post(name: AccessibilityPermissionMonitor.notification, object: nil)
    case .poll: monitor.refresh()
    }
    if trusted, step != .grant { everTrustedBeforeGrant = true }
    if granted > 1 {
      return ScenarioOutcome(invariant: "management-started-twice", message: "onGranted ran \(granted) times", log: log)
    }
    if granted == 1, !trusted, !everTrustedBeforeGrant {
      return ScenarioOutcome(invariant: "management-started-untrusted", message: "onGranted ran before any trust was confirmed", log: log)
    }
    if prompts > 1 {
      return ScenarioOutcome(invariant: "repeated-permission-prompt", message: "\(prompts) Accessibility prompts", log: log)
    }
  }
  // Once trust holds and macOS hints or polls, management must have started.
  if trusted, steps.contains(where: { $0 == .notify || $0 == .poll }), granted == 0,
    let lastGrant = steps.lastIndex(of: .grant),
    steps[lastGrant...].contains(where: { $0 == .notify || $0 == .poll }),
    !steps[lastGrant...].contains(.revoke)
  {
    return ScenarioOutcome(invariant: "management-never-started", message: "trust was granted and confirmed but onGranted never ran", log: log)
  }
  monitor.stop()
  return .passed
}

func generatePermissionScenario(seed: UInt64) -> [PermissionStep] {
  var random = SplitMix64(seed: seed)
  let all: [PermissionStep] = [.grant, .revoke, .notify, .poll]
  return (0..<(1 + random.below(8))).map { _ in all[random.below(all.count)] }
}

@Suite(.serialized)
struct PermissionScenarioTests {
  @Test @MainActor
  func accessibilityGrantStartsManagementOnceWithOnePrompt() async {
    let reports = await runScenarioCampaign(
      name: "permission",
      testFilter: "PermissionScenarioTests",
      defaultRuns: 500,
      generate: generatePermissionScenario,
      run: { runPermissionScenario($0) }
    )
    for report in reports { Issue.record(Comment(rawValue: report.text)) }
  }
}

struct KnownSuspectMatchTests {
  @Test func suspectCoversClassesWithMoreBehaviors() {
    let suspects = [#"focus-visible ["accessibilityRevoked"]"#: "note"]
    #expect(knownSuspect(#"focus-visible ["accessibilityRevoked", "busyAppTimesOut"]"#, in: suspects) == "note")
    #expect(knownSuspect(#"focus-visible ["busyAppTimesOut"]"#, in: suspects) == nil)
    #expect(knownSuspect(#"native-converges ["accessibilityRevoked"]"#, in: suspects) == nil)
  }
}
