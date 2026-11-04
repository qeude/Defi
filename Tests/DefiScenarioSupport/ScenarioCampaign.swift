import Foundation

/// A reproducible pseudo-random source: one seed replays a scenario bit for bit.
public struct SplitMix64: RandomNumberGenerator, Sendable {
  public var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  public mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  public mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
}

/// What a scenario step can be simplified to while shrinking, simplest first.
public protocol ShrinkableStep: Sendable, CustomStringConvertible {
  var simplifications: [Self] { get }
}

extension ShrinkableStep {
  public var simplifications: [Self] { [] }
}

/// The outcome of one scenario run.
public struct ScenarioOutcome: Sendable {
  /// Stable invariant code of the first violation, nil when every check held.
  public var invariant: String?
  public var message: String
  /// Catalog behaviors of the simulated macOS the run relied on; empty for pure runs.
  public var behaviors: Set<String>
  public var log: [String]

  public init(invariant: String?, message: String = "", behaviors: Set<String> = [], log: [String] = []) {
    self.invariant = invariant
    self.message = message
    self.behaviors = behaviors
    self.log = log
  }

  public static let passed = ScenarioOutcome(invariant: nil)

  /// Failure classes are an invariant plus the behaviors its minimal case needs.
  public var classKey: String { "\(invariant ?? "none") \(behaviors.sorted())" }
}

/// Removes chunks, then simplifies single steps, keeping every candidate that still breaks
/// the same invariant. Each candidate is replayed `replays` times so a flaky pass never
/// counts as a reproduction.
nonisolated(nonsending) public func shrinkScenario<Step: ShrinkableStep>(
  _ steps: [Step],
  invariant: String,
  replays: Int = 1,
  run: ([Step]) async -> ScenarioOutcome
) async -> [Step] {
  nonisolated(nonsending) func fails(_ candidate: [Step]) async -> Bool {
    for _ in 0..<replays where await run(candidate).invariant != invariant { return false }
    return true
  }
  var current = steps
  var chunk = max(1, current.count / 2)
  while chunk >= 1 {
    var index = 0
    var removed = false
    while index < current.count {
      var candidate = current
      candidate.removeSubrange(index..<min(index + chunk, current.count))
      if await fails(candidate) {
        current = candidate
        removed = true
      } else {
        index += chunk
      }
    }
    if !removed { chunk /= 2 }
  }
  var index = 0
  while index < current.count {
    var simplified = false
    for alternative in current[index].simplifications {
      var candidate = current
      candidate[index] = alternative
      if await fails(candidate) {
        current = candidate
        simplified = true
        break
      }
    }
    if !simplified { index += 1 }
  }
  return current
}

/// A reported failure class with everything needed to understand and replay it.
public struct ScenarioFailureReport: Sendable {
  public let classKey: String
  public let seed: UInt64
  public let text: String
  public let isKnownSuspect: Bool
}

/// A known suspect covers every class with its invariant whose behaviors include the suspect's:
/// "inv [a, b]" covers "inv [a, b, c]". Keys follow `ScenarioOutcome.classKey`.
public func knownSuspect(_ key: String, in suspects: [String: String]) -> String? {
  if let exact = suspects[key] { return exact }
  func split(_ key: String) -> (String, Set<String>) {
    guard let open = key.firstIndex(of: "[") else { return (key, []) }
    let invariant = String(key[..<open]).trimmingCharacters(in: .whitespaces)
    let names = key[open...].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
    return (invariant, Set(names.filter { !$0.isEmpty }))
  }
  let (invariant, behaviors) = split(key)
  return suspects.first { candidate in
    let (suspectInvariant, required) = split(candidate.key)
    return suspectInvariant == invariant && required.isSubset(of: behaviors)
  }?.value
}

/// Runs seeded scenarios, shrinks each new failure class to its minimal case, and reports
/// it once with the replay command. Classes listed in `knownSuspects` are printed but not
/// failed, so the loop stays green while a triaged suspect waits for confirmation.
nonisolated(nonsending) public func runScenarioCampaign<Step: ShrinkableStep>(
  name: String,
  testFilter: String,
  defaultRuns: Int,
  knownSuspects: [String: String] = [:],
  shrinkReplays: Int = 1,
  generate: (UInt64) -> [Step],
  run: ([Step]) async -> ScenarioOutcome
) async -> [ScenarioFailureReport] {
  let environment = ProcessInfo.processInfo.environment
  let runs = Int(environment["DEFI_SCENARIO_RUNS"] ?? "") ?? defaultRuns
  let firstSeed = UInt64(environment["DEFI_SCENARIO_SEED"] ?? "") ?? 1
  // DEFI_SCENARIO_SHARD=i/n runs every n-th seed from the i-th, so n processes split a campaign.
  let shard = (environment["DEFI_SCENARIO_SHARD"] ?? "0/1").split(separator: "/").compactMap { UInt64($0) }
  let (shardIndex, shardCount) = shard.count == 2 && shard[1] > 0 ? (shard[0], shard[1]) : (0, 1)
  let startedAt = Date()
  var reports: [String: ScenarioFailureReport] = [:]
  // A raw failure class seen a few times usually shrinks to a class already reported, so
  // later occurrences skip the replays; distinct bugs sharing a raw class still get 3 tries.
  var shrinksByRawClass: [String: Int] = [:]
  for seed in stride(from: firstSeed + shardIndex, to: firstSeed + UInt64(runs), by: Int(shardCount)) {
    let steps = generate(seed)
    let outcome = await run(steps)
    guard let invariant = outcome.invariant else { continue }
    shrinksByRawClass[outcome.classKey, default: 0] += 1
    guard shrinksByRawClass[outcome.classKey]! <= 3 else { continue }
    let minimal = await shrinkScenario(steps, invariant: invariant, replays: shrinkReplays, run: run)
    let minimalOutcome = await run(minimal)
    let key = minimalOutcome.invariant == nil ? outcome.classKey : minimalOutcome.classKey
    guard reports[key] == nil else { continue }
    let shown = minimalOutcome.invariant == nil ? outcome : minimalOutcome
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
    let suspect = knownSuspect(key, in: knownSuspects)
    let text = """
      [\(name)] \(suspect == nil ? "FAILURE" : "known suspect: \(suspect!)")
      invariant: \(shown.invariant ?? invariant): \(shown.message)
      catalog behaviors used: \(shown.behaviors.sorted())
      seed \(seed), found after \(seed - firstSeed + 1) runs in \(elapsed) s; \(steps.count) steps shrunk to \(minimal.count):
        \(minimal.map(\.description).joined(separator: "\n  "))
      replay: DEFI_ISOLATED=1 DEFI_SCENARIO_SEED=\(seed) DEFI_SCENARIO_RUNS=1 swift test --skip-build --filter '\(testFilter)'
      trace:
        \(shown.log.joined(separator: "\n  "))
      """
    print(text)
    reports[key] = ScenarioFailureReport(classKey: key, seed: seed, text: text, isKnownSuspect: suspect != nil)
  }
  print("[\(name)] \(runs) scenarios from seed \(firstSeed) (shard \(shardIndex)/\(shardCount)), \(reports.count) failure classes, \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s")
  return reports.values.sorted { $0.seed < $1.seed }
}
