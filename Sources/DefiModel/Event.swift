public enum NativeFocusResult: Equatable, Sendable {
  case completed
  case completedWithoutMutation
  case frameSuperseded
  case superseded
  case supersededAfterMutation
  case cancelled
  case cancelledAfterMutation
  case cancelledAfterInputMutation
  case failed
  case failedAfterMutation
}
