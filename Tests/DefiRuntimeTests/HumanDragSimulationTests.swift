import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Foundation
import Testing

/// Drags shaped like a hand's: a minimum-jerk reach with a curved path, tremor, a slow
/// vertical drift, sometimes an overshoot and its correction, then a rest before release.
/// Each sample goes through the drop target the overlay shows, threading the previous one.
struct HumanDragSimulationTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 25, width: 2_560, height: 1_339)
  private let rate = 60.0
  /// The display's full frame: the menu bar sits above the viewport.
  private let screen = Rect(x: 0, y: 0, width: 2_560, height: 1_364)

  enum Intent: CustomStringConvertible {
    case beside(gap: Int)
    case stack(column: Int, row: Int)
    var description: String {
      switch self {
      case .beside(let gap): "beside gap \(gap)"
      case .stack(let column, let row): row == 0 ? "above column \(column)" : "below column \(column)"
      }
    }
  }

  struct Outcome {
    var hits = 0, trials = 0, changes = 0, flickers = 0, lateChanges = 0, falseStacks = 0
    var misses: [String: Int] = [:]
  }

  @Test
  func humanDragsLandWhereTheyAim() throws {
    var rng = SplitMix64(seed: 97)
    let state = try makeState()
    let workspace = state.monitors[0].workspaces[0]
    let frames = Dictionary(uniqueKeysWithValues: computeLayout(
      workspace: workspace, viewport: viewport,
      windows: workspace.columns.flatMap(\.windows).compactMap { state.windows[$0] },
      settings: state.layout).map { ($0.windowID, $0.frame) })
    let held = workspace.columns[0].windows[0]
    let source = frames[held]!
    // The hand aims at the strip as the overlay shows it while held: without its window.
    let heldFrames = mouseDropPreviewFrames(in: mouseDropHeldState(held, state: state),
      viewports: [monitorID: viewport])
    let closed = Array(workspace.columns.dropFirst())
    let column = { (index: Int) in heldFrames[closed[index].windows[0]]! }
    let visible = closed.indices.filter { column($0).x + column($0).width <= viewport.x + viewport.width }
    try #require(!visible.isEmpty)
    var outcomes: [String: Outcome] = [:]

    for trial in 0..<600 {
      let start = (x: source.x + source.width * rng.uniform(0.3, 0.7), y: source.y + rng.uniform(8, 22))
      let intent: Intent
      let aim: (x: Double, y: Double)
      var lShaped = false
      switch trial % 3 {
      case 0:
        // Into the gap after a visible column, title bar at its usual height.
        let left = visible.randomElement(using: &rng)!
        let frame = column(left)
        intent = .beside(gap: left + 1)
        aim = (frame.x + frame.width + 4 + rng.gaussian(0, 25), start.y + rng.gaussian(0, 18))
      case 1:
        let target = visible.randomElement(using: &rng)!
        let frame = column(target)
        // Counted among the workspace's columns, the held window's own first.
        intent = .stack(column: target + 1, row: 1)
        aim = (frame.x + frame.width / 2 + rng.gaussian(0, frame.width * 0.12),
          frame.y + frame.height - rng.uniform(0, frame.height * 0.2))
        lShaped = rng.uniform(0, 1) < 0.5
      default:
        let target = visible.randomElement(using: &rng)!
        let frame = column(target)
        intent = .stack(column: target + 1, row: 0)
        // Pushed up above the other window, into the menu bar.
        aim = (frame.x + frame.width / 2 + rng.gaussian(0, frame.width * 0.12), viewport.y - rng.uniform(4, 24))
        lShaped = rng.uniform(0, 1) < 0.5
      }
      let path = humanPath(from: start, to: aim, lShaped: lShaped, rng: &rng)
      let expected = switch intent {
      case .beside(let gap): "column\(gap)"
      case .stack(let column, let row): "stack\(column).\(row)"
      }
      let kind = "\(intent)".components(separatedBy: " ")[0]
      // The overlay's own pipeline: hysteresis around the shown target.
      var shown: MouseDropTarget?
      var changes: [Int] = []
      var falseStack = false
      for (index, point) in path.points.enumerated() {
        let raw = mouseDropTarget(held, pointer: point, previous: shown, state: state,
          viewports: [monitorID: viewport], monitorFrames: [monitorID: screen])
        let next = raw
        if index > 0, next != shown {
          changes.append(index)
          if case .beside = intent, case .stack = next { falseStack = true }
        }
        shown = next
      }
      var outcome = outcomes[kind, default: Outcome()]
      outcome.trials += 1
      if shown.map(Self.label) == expected { outcome.hits += 1 } else {
        outcome.misses[shown.map(Self.label) ?? "none", default: 0] += 1
      }
      outcome.changes += changes.count
      outcome.flickers += zip(changes, changes.dropFirst()).filter { Double($1 - $0) / rate < 0.15 }.count
      // A stack shows after its longer settle, often once the hand rests: what matters is a
      // target that has stopped changing well before release.
      outcome.lateChanges += changes.filter { $0 >= path.points.count - Int(0.15 * rate) }.count
      if falseStack { outcome.falseStacks += 1 }
      outcomes[kind] = outcome
    }
    for (name, outcome) in outcomes.sorted(by: { $0.key < $1.key }) {
      let trials = Double(outcome.trials)
      print(String(format: "human-drag %@: hit %.0f%%, changes/drag %.1f, flickers/drag %.2f, late changes %d, false stacks %d, misses %@",
        name, 100 * Double(outcome.hits) / trials, Double(outcome.changes) / trials,
        Double(outcome.flickers) / trials, outcome.lateChanges, outcome.falseStacks,
        outcome.misses.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " ")))
      // Lands where aimed, on a target that stopped changing before release. The preview
      // follows the pointer at once: crossing a window's top shows a stack there on the way,
      // reported above, not held against a threshold.
      #expect(Double(outcome.hits) / trials >= 0.95, "\(name)")
      #expect(Double(outcome.lateChanges) / trials <= 0.05, "\(name)")
    }
  }

  private static func label(_ target: MouseDropTarget) -> String {
    switch target {
    case .column(let index): "column\(index)"
    case .stack(let stack): "stack\(stack.columnIndex).\(stack.row)"
    case .rejectedStack(let stack): "rejected\(stack.columnIndex).\(stack.row)"
    case .display: "display"
    }
  }

  /// Samples at the overlay's rate: a reach (two for an L-shaped move or an overshoot
  /// and its correction), then a resting hand.
  private func humanPath(
    from start: (x: Double, y: Double), to aim: (x: Double, y: Double), lShaped: Bool, rng: inout SplitMix64
  ) -> (points: [(x: Double, y: Double)], restStart: Int) {
    var waypoints = [start]
    if lShaped { waypoints.append((aim.x + rng.gaussian(0, 20), start.y + rng.gaussian(0, 15))) }
    if rng.uniform(0, 1) < 0.35 {
      let last = waypoints.last!
      let overshoot = rng.uniform(0.04, 0.12)
      waypoints.append((aim.x + (aim.x - last.x) * overshoot, aim.y + (aim.y - last.y) * overshoot))
    }
    waypoints.append(aim)
    var points: [(x: Double, y: Double)] = []
    var tremor = (x: 0.0, y: 0.0)
    func sample(_ point: (x: Double, y: Double)) {
      tremor = (0.7 * tremor.x + rng.gaussian(0, 1.2), 0.7 * tremor.y + rng.gaussian(0, 1.2))
      // A real pointer stops at the display's edges.
      points.append((min(max(point.x + tremor.x, screen.x), screen.x + screen.width - 1),
        min(max(point.y + tremor.y, screen.y), screen.y + screen.height - 1)))
    }
    for (from, to) in zip(waypoints, waypoints.dropFirst()) {
      let distance = hypot(to.x - from.x, to.y - from.y)
      let duration = (0.18 + 0.11 * log2(distance / 30 + 1)) * rng.uniform(0.8, 1.3)
      let bow = rng.gaussian(0, 0.06) * distance
      let steps = max(Int(duration * rate), 2)
      for step in 1...steps {
        let t = Double(step) / Double(steps)
        let s = 10 * pow(t, 3) - 15 * pow(t, 4) + 6 * pow(t, 5)
        let normal = distance > 0 ? (x: -(to.y - from.y) / distance, y: (to.x - from.x) / distance) : (x: 0, y: 0)
        let arc = bow * sin(.pi * s)
        sample((from.x + (to.x - from.x) * s + normal.x * arc, from.y + (to.y - from.y) * s + normal.y * arc))
      }
      // A short pause between submovements.
      for _ in 0..<Int(rng.uniform(0.03, 0.12) * rate) { sample(to) }
    }
    let restStart = points.count
    for _ in 0..<Int(0.35 * rate) { sample(aim) }
    return (points, restStart)
  }

  /// Four columns on a 2560-point display, as on a laptop docked to an external screen.
  private func makeState() throws -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    for rawID in 1...4 {
      try discoverWindow(
        Window(id: WindowID(rawValue: UInt64(rawID)), appID: "editor", title: "Window \(rawID)",
          frame: Rect(x: 0, y: 25, width: 800, height: 1_300), monitorID: monitorID),
        decision: RuleDecision(followFocus: true), isNativelyFocused: true, state: &state)
    }
    // Three columns fit on screen, the fourth waits past the edge.
    for index in state.monitors[0].workspaces[0].columns.indices {
      state.monitors[0].workspaces[0].columns[index].width = .pixels(780)
    }
    restoreWorkspaceScroll(
      WorkspaceScrollAnchor(monitorID: monitorID, workspaceID: state.monitors[0].workspaces[0].id, scrollOffset: 0),
      state: &state)
    return state
  }
}

struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func uniform(_ low: Double, _ high: Double) -> Double { Double.random(in: low..<high, using: &self) }
  mutating func gaussian(_ mean: Double, _ deviation: Double) -> Double {
    let u = max(uniform(0, 1), 1e-12), v = uniform(0, 1)
    return mean + deviation * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
  }
}
