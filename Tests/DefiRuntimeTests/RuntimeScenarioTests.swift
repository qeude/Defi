import DefiConfig
import DefiCore
import DefiModel
import DefiScenarioSupport
import Foundation
import Testing

@testable import DefiRuntime

/// One user or desktop action applied to the pure runtime, the way the daemon applies it.
enum RuntimeStep: ShrinkableStep, Equatable {
  case open(app: Int, floating: Bool, constraint: Int = 0)
  case close(Int)
  case command(Command, monitor: Int)
  case nativeFocus(Int)
  /// 0: built-in only, 1: built-in and external, 2: external only.
  case displays(Int)

  var description: String {
    switch self {
    case .open(let app, let floating, let constraint):
      "open(app: \(app)\(floating ? ", floating" : "")\(constraint == 0 ? "" : ", \(openConstraints[constraint].name)"))"
    case .close(let index): "close(\(index))"
    case .command(let command, let monitor): "command(\(command), monitor: \(monitor))"
    case .nativeFocus(let index): "nativeFocus(\(index))"
    case .displays(let layout): "displays(\(layout))"
    }
  }

  var simplifications: [RuntimeStep] {
    switch self {
    case .open(let app, let floating, let constraint) where floating || constraint != 0:
      (constraint != 0 ? [.open(app: app, floating: floating)] : [])
        + (floating ? [.open(app: app, floating: false, constraint: constraint)] : [])
    case .command(let command, 1): [.command(command, monitor: 0)]
    default: []
    }
  }
}

/// Size constraints apps report; the runtime learns them from native frames.
let openConstraints: [(name: String, apply: @Sendable (inout Window) -> Void)] = [
  ("none", { _ in }),
  ("max width 500", { $0.maximumTiledWidth = 500 }),
  ("min width 1000", { $0.minimumTiledWidth = 1_000 }),
  ("min height 600", { $0.minimumTiledHeight = 600 }),
  ("max height 450", { $0.maximumTiledHeight = 450 }),
]

let scenarioCommands: [Command] = [
  .focusColumn(.left), .focusColumn(.right), .focusWindow(.up), .focusWindow(.down),
  .moveColumn(.left), .moveColumn(.right), .moveWindow(.left), .moveWindow(.right),
  .moveWindow(.up), .moveWindow(.down), .moveColumnToMonitor(.right), .moveColumnToMonitor(.left),
  .moveWindowToMonitor(.right), .focusWorkspace(.relative(.next)),
  .focusWorkspace(.relative(.previous)), .focusWorkspace(.position(1)),
  .focusWorkspace(.position(3)), .focusWorkspace(.lastActive),
  .moveColumnToWorkspace(.relative(.next), follow: false),
  .moveColumnToWorkspace(.relative(.next), follow: true),
  .moveWindowToWorkspaceTarget(.relative(.previous), follow: false),
  .reorderWorkspace(.up), .reorderWorkspace(.down), .moveWorkspaceToMonitor(.right),
  .focusMonitor(.right), .focusMonitor(.left), .cycleWidth(.next), .maximizeColumn,
  .centerColumn, .toggleFloating, .joinWindow(.left), .joinWindow(.right), .unjoinWindows,
  .focusWindowOrWorkspace(.down), .focusWindowOrWorkspace(.up), .focusFloating(.next),
  .focusWorkspace(.position(2)), .focusWorkspace(.named("mail")), .moveColumnToWorkspace(.named("code"), follow: true),
  .moveWindowToWorkspaceTarget(.named("mail"), follow: false), .moveWorkspaceToMonitor(.left),
]

/// Two side-by-side displays; the external one is taller so the staircase matters.
let scenarioDisplays: [(id: MonitorID, frame: Rect, visible: Rect)] = [
  (MonitorID(rawValue: 1), Rect(x: 0, y: 0, width: 1_440, height: 900),
   Rect(x: 0, y: 25, width: 1_440, height: 875)),
  (MonitorID(rawValue: 2), Rect(x: 1_440, y: 0, width: 1_920, height: 1_080),
   Rect(x: 1_440, y: 25, width: 1_920, height: 1_055)),
]

struct RuntimeWorld {
  let config: Config
  var state: RuntimeState
  var discovered: [Window] = []
  var nextWindowID: UInt64 = 1
  var connected: [Int] = []
  var log: [String] = []
  /// Broken command intents, checked against what the user asked rather than the reducer.
  var intentViolations: [InvariantViolation] = []

  init(config: Config = Config()) {
    self.config = config
    state = RuntimeState(config: config)
    connect([0])
  }

  var viewports: [MonitorID: Rect] {
    Dictionary(uniqueKeysWithValues: connected.map {
      (scenarioDisplays[$0].id, scenarioDisplays[$0].visible)
    })
  }

  mutating func connect(_ displays: [Int]) {
    let previous = viewports
    connected = displays
    state.retainMonitors(
      displays.map { scenarioDisplays[$0].id },
      previousViewports: previous,
      nextViewports: viewports
    )
  }

  mutating func reconcile(nativeFocus: WindowID? = nil) {
    reconcileWindows(
      discovered, config: config, viewports: viewports,
      nativeFocusedWindowID: nativeFocus, state: &state
    )
    synchronizeScrollOffsets(state: &state, viewports: viewports)
  }

  mutating func apply(_ step: RuntimeStep) {
    switch step {
    case .open(let app, let floating, let constraint):
      let display = scenarioDisplays[connected[0]]
      let id = WindowID(rawValue: nextWindowID)
      nextWindowID += 1
      var window = Window(
        id: id, appID: "app.\(app)", title: "",
        frame: Rect(x: display.visible.x + 40, y: display.visible.y + 40, width: 600, height: 400),
        processID: Int32(100 + app), monitorID: display.id,
        floating: floating, floatingOrigin: floating ? .automatic : nil
      )
      openConstraints[constraint % openConstraints.count].apply(&window)
      discovered.append(window)
      reconcile()
      if !floating, let location = state.location(containing: id),
        let monitor = state.monitors.first(where: { $0.id == location.monitorID }),
        location.workspaceID != monitor.activeWorkspace
      {
        intentViolations.append(.init(
          "new-window-off-active-workspace",
          "new window \(id) opened in \(location.workspaceID), not active \(monitor.activeWorkspace)"
        ))
      }
    case .close(let index):
      guard !discovered.isEmpty else { return }
      discovered.remove(at: index % discovered.count)
      reconcile()
    case .command(let command, let monitor):
      let monitorID = connected.indices.contains(monitor)
        ? scenarioDisplays[connected[monitor]].id : nil
      let frames = Dictionary(uniqueKeysWithValues: connected.map {
        (scenarioDisplays[$0].id, scenarioDisplays[$0].frame)
      })
      let before = state
      do {
        try reduce(command, on: monitorID, state: &state, monitorFrames: frames, viewports: viewports)
        // The daemon reconciles scroll and stacks after every command.
        synchronizeScrollOffsets(state: &state, viewports: viewports)
        checkIntent(of: command, on: monitorID, before: before)
      } catch {
        log.append("  rejected: \(error)")
      }
    case .nativeFocus(let index):
      guard !discovered.isEmpty else { return }
      let id = discovered[index % discovered.count].id
      _ = focusWindow(id, state: &state)
      reconcile(nativeFocus: id)
    case .displays(let layout):
      connect([[0], [0, 1], [1]][layout % 3])
      synchronizeScrollOffsets(state: &state, viewports: viewports)
    }
  }
}

extension RuntimeWorld {
  /// Postconditions a user can see for commands with an unambiguous outcome.
  mutating func checkIntent(of command: Command, on requestedMonitorID: MonitorID?, before: RuntimeState) {
    let monitorID = requestedMonitorID ?? before.monitors.first?.id
    guard let monitorID else { return }
    let selectedBefore = before.selectedWindowID(on: monitorID)
    func fail(_ code: String, _ message: String) {
      intentViolations.append(.init(code, "\(command): \(message)"))
    }
    switch command {
    case .focusWorkspace(.named(let name)):
      let id = WorkspaceID(rawValue: name)
      guard let owner = state.monitors.first(where: { $0.workspaces.contains { $0.id == id } }) else {
        return fail("named-workspace-missing", "\(name) has no monitor")
      }
      if owner.activeWorkspace != id {
        fail("focus-workspace-ignored", "\(name) is not active on its monitor \(owner.id)")
      }
    case .moveColumnToWorkspace(_, follow: true), .moveWindowToWorkspaceTarget(_, follow: true):
      guard let moved = selectedBefore, let location = state.location(containing: moved),
        let beforeLocation = before.location(containing: moved),
        location.workspaceID != beforeLocation.workspaceID
      else { return }
      let owner = state.monitors.first { $0.id == location.monitorID }
      if owner?.activeWorkspace != location.workspaceID
        || state.selectedWindowID(on: location.monitorID) != moved
      {
        fail("follow-lost-window", "moved window \(moved) to \(location.workspaceID) but it is not the selection there")
      }
    case .moveColumnToWorkspace(_, follow: false), .moveWindowToWorkspaceTarget(_, follow: false):
      guard let moved = selectedBefore, let location = state.location(containing: moved),
        location.workspaceID != before.location(containing: moved)?.workspaceID
      else { return }
      if state.selectedWindowID(on: monitorID) == moved,
        state.monitors.first(where: { $0.id == monitorID })?.activeWorkspace != location.workspaceID
      {
        fail("send-kept-selection", "sent window \(moved) away but the monitor still selects it")
      }
    case .focusColumn(let direction) where direction == .left || direction == .right:
      guard let monitor = before.monitors.first(where: { $0.id == monitorID }),
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.focusedLayer == .tiled, workspace.columns.indices.contains(workspace.focusedColumn)
      else { return }
      let target = workspace.focusedColumn + (direction == .right ? 1 : -1)
      guard workspace.columns.indices.contains(target) else { return }
      let column = workspace.columns[target]
      // A stale row index is the triaged focus-index-out-of-range bug, not a new intent loss.
      if !column.windows.indices.contains(column.focusedWindow),
        RuntimeScenarioTests.knownCodes["focus-index-out-of-range"] != nil
      { return }
      let expected = column.windows[min(max(column.focusedWindow, 0), column.windows.count - 1)]
      if state.selectedWindowID(on: monitorID) != expected {
        fail("focus-column-missed", "expected window \(expected), selection is \(String(describing: state.selectedWindowID(on: monitorID)))")
      }
    case .focusWorkspace(.position(let position)) where position > 0:
      guard let before = before.monitors.first(where: { $0.id == monitorID }), !before.workspaces.isEmpty,
        let after = state.monitors.first(where: { $0.id == monitorID })
      else { return }
      let target = before.workspaces[min(position - 1, before.workspaces.count - 1)].id
      if after.activeWorkspace != target {
        fail("focus-workspace-position", "expected workspace \(target) at position \(position), active is \(after.activeWorkspace)")
      }
    case .joinWindow(let direction) where direction == .left || direction == .right:
      guard let joined = selectedBefore,
        let monitor = before.monitors.first(where: { $0.id == monitorID }),
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.focusedLayer == .tiled,
        let column = workspace.columns.firstIndex(where: { $0.windows.contains(joined) }),
        workspace.columns.indices.contains(column + (direction == .right ? 1 : -1))
      else { return }
      // A stale row index is the triaged focus-index-out-of-range bug, not a new intent loss.
      if RuntimeScenarioTests.knownCodes["focus-index-out-of-range"] != nil,
        state.monitors.flatMap(\.workspaces).flatMap(\.columns).contains(where: {
          !$0.windows.indices.contains($0.focusedWindow)
        })
      { return }
      if state.selectedWindowID(on: monitorID) != joined {
        fail("join-lost-window", "joined window \(joined) is not the selection, \(String(describing: state.selectedWindowID(on: monitorID))) is")
      }
    case .toggleFloating:
      guard let window = selectedBefore,
        let wasFloating = before.monitors.flatMap(\.workspaces).first(where: {
          $0.floatingWindows.contains(window) || $0.columns.contains { $0.windows.contains(window) }
        }).map({ $0.floatingWindows.contains(window) })
      else { return }
      let isFloating = state.monitors.flatMap(\.workspaces).contains { $0.floatingWindows.contains(window) }
      if isFloating == wasFloating {
        fail("toggle-floating-ignored", "window \(window) stayed \(wasFloating ? "floating" : "tiled")")
      }
    default:
      return
    }
  }
}

func runRuntimeScenario(_ steps: [RuntimeStep], config: Config = Config()) -> ScenarioOutcome {
  var world = RuntimeWorld(config: config)
  for step in steps {
    world.log.append(step.description)
    world.apply(step)
    let connected = world.connected.map { scenarioDisplays[$0] }
    let violations = world.intentViolations + world.state.validate()
      + layoutViolations(state: world.state, displays: connected)
    if let violation = violations.first(where: { !RuntimeScenarioTests.skippedCodes.contains($0.code) }) {
      return ScenarioOutcome(invariant: violation.code, message: violation.message, log: world.log)
    }
  }
  return .passed
}

func generateRuntimeScenario(seed: UInt64) -> [RuntimeStep] {
  var random = SplitMix64(seed: seed)
  return (0..<(6 + random.below(30))).map { _ in
    switch random.below(100) {
    case 0..<22: .open(
      app: random.below(3), floating: random.chance(20),
      constraint: random.chance(35) ? 1 + random.below(openConstraints.count - 1) : 0)
    case 22..<32: .close(random.below(8))
    case 32..<85: .command(scenarioCommands[random.below(scenarioCommands.count)], monitor: random.below(2))
    case 85..<93: .nativeFocus(random.below(8))
    default: .displays(random.below(3))
    }
  }
}

/// Outer and inner gaps exercise the edge spacing rules.
let gapConfig: Config = {
  var config = Config()
  config.layout.gaps = 12
  config.layout.outerTopGap = 20
  config.layout.outerBottomGap = 8
  return config
}()

/// Named workspaces exercise persistence and the reserved-name rules.
let namedWorkspaceConfig: Config = {
  var config = Config()
  config.workspaces.names = ["mail", "code"]
  return config
}()

struct RuntimeScenarioTests {
  /// Triaged violations the loop skips while they wait for a fix: code -> status and issue.
  /// A skipped code hides only its own violation; the scenario keeps checking every other rule.
  static let knownCodes: [String: String] = [
    "focus-index-out-of-range":
      "bug: joinWindow(.right) from a stack leaves the source column's row index stale (joinFocusedWindow); issue pending",
  ]
  static let knownSuspects: [String: String] = [:]
  /// Known codes plus DEFI_SCENARIO_SKIP (comma separated), which retro-validation uses to
  /// look past violations that persist on both sides of a fix.
  static let skippedCodes: Set<String> = Set(knownCodes.keys).union(
    (ProcessInfo.processInfo.environment["DEFI_SCENARIO_SKIP"] ?? "").split(separator: ",").map(String.init)
  )

  @Test func randomRuntimeScenariosKeepInvariants() async {
    for (name, config) in [("default", Config()), ("named", namedWorkspaceConfig), ("gaps", gapConfig)] {
      let reports = await runScenarioCampaign(
        name: "runtime/\(name)",
        testFilter: "RuntimeScenarioTests/randomRuntimeScenariosKeepInvariants",
        defaultRuns: 1_000,
        knownSuspects: Self.knownSuspects,
        generate: generateRuntimeScenario,
        run: { runRuntimeScenario($0, config: config) }
      )
      for report in reports where !report.isKnownSuspect {
        Issue.record(Comment(rawValue: report.text))
      }
    }
  }

  static let exhaustiveSetup: [RuntimeStep] = [
    .displays(1), .open(app: 0, floating: false), .open(app: 1, floating: false),
    .open(app: 1, floating: true), .command(.moveColumnToMonitor(.right), monitor: 0),
    .open(app: 2, floating: false), .open(app: 2, floating: false),
  ]

  /// `make check` covers a representative alphabet; DEFI_SCENARIO_DEEP=1 covers every command.
  static let exhaustiveAlphabet: [RuntimeStep] = {
    let deep = ProcessInfo.processInfo.environment["DEFI_SCENARIO_DEEP"] == "1"
    let commands: [Command] = deep ? scenarioCommands : [
      .focusColumn(.left), .focusColumn(.right), .focusWindow(.up), .moveColumn(.left),
      .moveWindow(.right), .moveWindow(.up), .moveColumnToMonitor(.right),
      .focusWorkspace(.relative(.next)), .focusWorkspace(.lastActive),
      .moveColumnToWorkspace(.relative(.next), follow: true), .reorderWorkspace(.down),
      .moveWorkspaceToMonitor(.right), .focusMonitor(.left), .maximizeColumn, .toggleFloating,
      .joinWindow(.left), .joinWindow(.right), .unjoinWindows, .focusWindowOrWorkspace(.down),
    ]
    return commands.map { .command($0, monitor: 0) } + [
      .open(app: 0, floating: false), .close(0), .close(3), .nativeFocus(1), .nativeFocus(4),
      .displays(0), .displays(2), .command(.focusColumn(.left), monitor: 1),
    ]
  }()

  /// Every three-action sequence after a fixed two-display, mixed-window setup; one case per
  /// first action so the cases run in parallel.
  @Test(arguments: exhaustiveAlphabet.indices)
  func shortRuntimeSequencesKeepInvariantsExhaustively(first: Int) {
    let alphabet = Self.exhaustiveAlphabet
    var failures: [String: String] = [:]
    for second in alphabet {
      for third in alphabet {
        let outcome = runRuntimeScenario(Self.exhaustiveSetup + [alphabet[first], second, third])
        guard let invariant = outcome.invariant, failures[invariant] == nil else { continue }
        failures[invariant] = "\(invariant): \(outcome.message)\n  \(outcome.log.joined(separator: "\n  "))"
      }
    }
    for failure in failures.values.sorted() {
      Issue.record(Comment(rawValue: failure))
    }
  }
}
