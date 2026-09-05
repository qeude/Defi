import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct InternalFocusSuppression: Equatable, Sendable {
  let requestID: UInt64
  let deadline: TimeInterval
  let maximumInputTimestamp: TimeInterval
  let isInFlight: Bool

  init(
    requestID: UInt64,
    deadline: TimeInterval,
    maximumInputTimestamp: TimeInterval,
    isInFlight: Bool = true
  ) {
    self.requestID = requestID
    self.deadline = deadline
    self.maximumInputTimestamp = maximumInputTimestamp
    self.isInFlight = isInFlight
  }
}

func internalFocusSuppressionConsumesEvent(
  _ suppression: InternalFocusSuppression,
  suppressedWindowID: WindowID,
  latestFocusIntent: UserInputTracker.FocusIntent?,
  applicationActivation: Bool = false
) -> Bool {
  guard let latestFocusIntent,
    latestFocusIntent.timestamp > suppression.maximumInputTimestamp
  else {
    return true
  }
  if applicationActivation { return false }
  switch latestFocusIntent.source {
  case .keyboard:
    return false
  case .mouse(let windowID):
    return windowID != suppressedWindowID
  }
}

func extendingInternalFocusSuppression(
  _ suppression: InternalFocusSuppression,
  through inputTimestamp: TimeInterval,
  deadline: TimeInterval
) -> InternalFocusSuppression {
  InternalFocusSuppression(
    requestID: suppression.requestID,
    deadline: max(suppression.deadline, deadline),
    maximumInputTimestamp: max(
      suppression.maximumInputTimestamp,
      inputTimestamp
    ),
    isInFlight: suppression.isInFlight
  )
}

func internalFocusSuppressionAfterCompletion(
  _ suppression: InternalFocusSuppression?,
  requestID: UInt64,
  result: NativeFocusResult
) -> InternalFocusSuppression? {
  guard let suppression, suppression.requestID == requestID else {
    return suppression
  }
  switch result {
  case .completedWithoutMutation, .frameSuperseded, .superseded, .cancelled:
    return nil
  case .completed:
    return InternalFocusSuppression(
      requestID: suppression.requestID,
      deadline: suppression.deadline,
      maximumInputTimestamp: suppression.maximumInputTimestamp,
      isInFlight: false
    )
  case .supersededAfterMutation, .cancelledAfterMutation,
    .cancelledAfterInputMutation, .failed, .failedAfterMutation:
    return suppression
  }
}

func focusSuppressionsAfterRecoveryInvalidation(
  _ suppressions: [WindowID: InternalFocusSuppression],
  now: TimeInterval,
  preservingCompleted: Bool
) -> [WindowID: InternalFocusSuppression] {
  suppressions.filter {
    $0.value.deadline >= now
      && (preservingCompleted || $0.value.isInFlight)
  }
}
