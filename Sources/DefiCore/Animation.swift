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

public struct SpringScalarStep: Equatable, Sendable {
  public let value: Double
  public let velocity: Double

  public init(value: Double, velocity: Double) {
    self.value = value
    self.velocity = velocity
  }
}

public struct SpringProgressSample: Equatable, Sendable {
  public let progress: Double
  public let velocity: Double

  public init(progress: Double, velocity: Double) {
    self.progress = progress
    self.velocity = velocity
  }
}

public func criticallyDampedSpringStep(
  value: Double,
  target: Double,
  velocity: Double,
  deltaTime: TimeInterval,
  response: TimeInterval
) -> SpringScalarStep {
  guard deltaTime > 0, response > 0 else {
    return SpringScalarStep(value: target, velocity: 0)
  }
  let omega = 6 / response
  let displacement = value - target
  let velocityTerm = velocity + omega * displacement
  let decay = exp(-omega * deltaTime)
  return SpringScalarStep(
    value: target + (displacement + velocityTerm * deltaTime) * decay,
    velocity: (velocity - omega * velocityTerm * deltaTime) * decay
  )
}

public func completedFrameSpringProgresses(
  duration: TimeInterval,
  refreshRateHz: Double
) -> [Double] {
  completedFrameSpringSamples(
    duration: duration,
    refreshRateHz: refreshRateHz
  ).map(\.progress)
}

public func completedFrameSpringSamples(
  duration: TimeInterval,
  refreshRateHz: Double,
  initialVelocity: Double = 0
) -> [SpringProgressSample] {
  guard duration > 0 else { return [] }
  let refreshRate = min(max(refreshRateHz, 30), 120)
  let interval = 1 / refreshRate
  let response = max(duration * 1.5, 0.04)
  let frameCount = max(Int(ceil(duration / interval)) - 1, 1)
  var value = 0.0
  var velocity = min(max(initialVelocity, 0), 6 / response)
  return (0..<frameCount).map { _ in
    let step = criticallyDampedSpringStep(
      value: value,
      target: 1,
      velocity: velocity,
      deltaTime: interval,
      response: response
    )
    value = min(max(step.value, value), 1)
    velocity = value >= 1 ? 0 : max(step.velocity, 0)
    return SpringProgressSample(progress: value, velocity: velocity)
  }
}

public func retainedSpringProgressVelocity(
  normalizedCandidates: [Double],
  maximum: Double
) -> Double {
  let valid = normalizedCandidates
    .filter { $0.isFinite && $0 > 0 }
    .sorted()
  guard !valid.isEmpty else { return 0 }
  return min(valid[valid.count / 2], max(maximum, 0))
}

public func adaptiveIntermediateFrameLimit(
  predictedFrameLatency: TimeInterval,
  refreshRateHz: Double,
  availableIntermediateFrames: Int
) -> Int {
  guard availableIntermediateFrames > 0 else { return 0 }
  let latency = max(predictedFrameLatency, 0)
  let refreshRate = min(max(refreshRateHz, 30), 120)
  if latency >= 1 / refreshRate {
    let budget = Double(availableIntermediateFrames) / refreshRate
    return min(
      max(Int(floor(budget / latency)) - 1, 0),
      availableIntermediateFrames
    )
  }
  return availableIntermediateFrames
}

public func anticipatedFinalFrameDispatchDelay(
  animationDuration: TimeInterval,
  predictedFrameLatency: TimeInterval
) -> TimeInterval {
  max(animationDuration - max(predictedFrameLatency, 0), 0)
}


public func speculativeNavigationSettlementDelay(
  animationDuration: TimeInterval
) -> TimeInterval {
  min(max(max(animationDuration, 0) + 0.04, 0.075), 0.12)
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
  maximumAbsoluteDelta: Double
) -> DisplayedScalarRebase? {
  let valid = expectedMinusDisplayedDeltas
    .filter { $0.isFinite && abs($0) <= maximumAbsoluteDelta }
    .sorted()
  guard !valid.isEmpty else { return nil }
  let delta = valid[valid.count / 2]
  guard abs(delta) >= 0.5 else { return nil }
  return DisplayedScalarRebase(
    value: logicalValue + delta,
    delta: delta
  )
}
