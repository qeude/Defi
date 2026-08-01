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
  refreshRateHz: Double,
  maximumIntermediateFrames: Int = 4
) -> [Double] {
  guard duration > 0, maximumIntermediateFrames > 0 else { return [] }
  let refreshRate = min(max(refreshRateHz, 30), 120)
  let interval = 1 / refreshRate
  let response = max(duration * 1.5, 0.04)
  let frameCount = min(
    max(Int(ceil(duration / interval)) - 1, 1),
    maximumIntermediateFrames
  )
  var value = 0.0
  var velocity = 0.0
  return (0..<frameCount).map { _ in
    let step = criticallyDampedSpringStep(
      value: value,
      target: 1,
      velocity: velocity,
      deltaTime: interval,
      response: response
    )
    value = min(max(step.value, 0), 1)
    velocity = step.velocity
    return value
  }
}

public func shouldEmitAnotherIntermediateFrame(
  elapsed: TimeInterval,
  predictedFrameLatency: TimeInterval,
  budget: TimeInterval,
  completedIntermediateFrames: Int
) -> Bool {
  guard elapsed < budget else { return false }
  guard completedIntermediateFrames > 0 else { return true }
  return elapsed + max(predictedFrameLatency, 0) < budget
}

public func adaptiveIntermediateFrameLimit(
  predictedFrameLatency: TimeInterval,
  refreshRateHz: Double,
  availableIntermediateFrames: Int
) -> Int {
  guard availableIntermediateFrames > 0 else { return 0 }
  let latency = max(predictedFrameLatency, 0)
  if latency >= 0.025 {
    return 1
  }
  let refreshRate = min(max(refreshRateHz, 30), 120)
  if latency >= 1 / refreshRate {
    return 1
  }
  return availableIntermediateFrames
}

public func anticipatedSpringProgressIndex(
  predictedFrameLatency: TimeInterval,
  refreshRateHz: Double,
  availableIntermediateFrames: Int,
  minimumIndex: Int = 0,
  maximumIndex: Int? = nil
) -> Int? {
  guard availableIntermediateFrames > 0 else { return nil }
  let refreshRate = min(max(refreshRateHz, 30), 120)
  let interval = 1 / refreshRate
  let completedIntervals = max(
    Int(ceil(max(predictedFrameLatency, interval) / interval)),
    1
  )
  let anticipated = min(
    max(completedIntervals - 1, minimumIndex),
    availableIntermediateFrames - 1
  )
  return min(anticipated, maximumIndex ?? anticipated)
}

public func completedFrameSupportsAnotherSample(
  duration: TimeInterval,
  refreshRateHz: Double
) -> Bool {
  let refreshRate = min(max(refreshRateHz, 30), 120)
  let maximumDuration = max(1.5 / refreshRate, 0.012)
  return max(duration, 0) < maximumDuration
}

public func nextCompletedFrameDispatchDeadline(
  completedAt: TimeInterval,
  refreshRateHz: Double
) -> TimeInterval {
  let refreshRate = min(max(refreshRateHz, 30), 120)
  return completedAt + 1 / refreshRate
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
