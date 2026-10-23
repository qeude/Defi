import Foundation

public func animatedScalar(
  from: Double,
  to: Double,
  elapsed: TimeInterval,
  duration: TimeInterval
) -> Double {
  guard duration > 0 else { return to }
  let progress = min(max(elapsed / duration, 0), 1)
  let inverse = 1 - progress
  let eased = 1 - inverse * inverse * inverse
  return from + (to - from) * eased
}

public struct DisplayedScalarRebase: Equatable, Sendable {
  public let value: Double
  public let delta: Double

  public init(value: Double, delta: Double) {
    self.value = value
    self.delta = delta
  }
}

public func rebaseScalarToDisplayedFrames(
  logicalValue: Double,
  expectedMinusDisplayedDeltas: [Double],
  maximumAbsoluteDelta: Double,
  logicalScale: Double = 1
) -> DisplayedScalarRebase? {
  guard logicalScale.isFinite, logicalScale > 0 else { return nil }
  let valid = expectedMinusDisplayedDeltas
    .filter { $0.isFinite && abs($0) <= maximumAbsoluteDelta }
    .sorted()
  guard !valid.isEmpty else { return nil }
  let delta = valid[valid.count / 2]
  guard abs(delta) >= 0.5 else { return nil }
  return DisplayedScalarRebase(
    value: logicalValue + delta / logicalScale,
    delta: delta
  )
}
