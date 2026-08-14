import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct FocusInputGuard: @unchecked Sendable {
  let tracker: UserInputTracker
  let maximumTimestamp: TimeInterval
}

struct AsyncFocusRequest: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
  let processID: pid_t
  let selectsSpecificWindow: Bool
  let validatesSpecificWindowFocus: Bool
  let activatesApplication: Bool
  let inputGuard: FocusInputGuard?
  let recoveryRequest: NativeFocusRecoveryRequest?
}

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

public struct NativeFocusRequestID: Equatable, Sendable {
  let rawValue: UInt64
}

func focusRecoveryIntentIsCurrent(
  requestGeneration: UInt64,
  currentGeneration: UInt64
) -> Bool {
  requestGeneration == currentGeneration
}

func focusRequestCanBeCancelled(
  requestGeneration: UInt64,
  latestGeneration: UInt64,
  pendingGeneration: UInt64?,
  activeGeneration: UInt64?
) -> Bool {
  requestGeneration == latestGeneration
    && (pendingGeneration == requestGeneration
      || activeGeneration == requestGeneration)
}

struct NativeFocusRecoveryFallback: Equatable, Sendable {
  let windowID: WindowID?
  let processID: pid_t?
}

struct NativeFocusRecoveryRequest: Equatable, Sendable {
  let timestamp: TimeInterval
  let excludingWindowID: WindowID
  let excludingProcessID: pid_t
  let fallback: NativeFocusRecoveryFallback?
  let fallbackOnlyIfNoNewerInput: Bool

  init(
    timestamp: TimeInterval,
    excludingWindowID: WindowID,
    excludingProcessID: pid_t,
    fallback: NativeFocusRecoveryFallback?,
    fallbackOnlyIfNoNewerInput: Bool = false
  ) {
    self.timestamp = timestamp
    self.excludingWindowID = excludingWindowID
    self.excludingProcessID = excludingProcessID
    self.fallback = fallback
    self.fallbackOnlyIfNoNewerInput = fallbackOnlyIfNoNewerInput
  }
}

func nativeFocusRecoveryFallbackTarget(
  _ request: NativeFocusRecoveryRequest,
  latestEventTimestamp: TimeInterval
) -> UserInputTracker.FocusRecoveryTarget? {
  guard request.fallbackOnlyIfNoNewerInput,
    let fallback = request.fallback,
    latestEventTimestamp <= request.timestamp
  else {
    return nil
  }
  return UserInputTracker.FocusRecoveryTarget(
    timestamp: request.timestamp,
    windowID: fallback.windowID,
    processID: fallback.processID
  )
}

struct NativeFocusCompletion: Equatable, Sendable {
  let result: NativeFocusResult
  let recoveryRequest: NativeFocusRecoveryRequest?
}

struct NativeFocusRecoveryTransfer: Equatable, Sendable {
  let carried: NativeFocusRecoveryRequest?
  let recovery: NativeFocusRecoveryRequest?
}

func transferredNativeFocusRecovery(
  carried: NativeFocusRecoveryRequest?,
  request: NativeFocusRecoveryRequest?,
  result: NativeFocusResult,
  generationCurrent: Bool
) -> NativeFocusRecoveryTransfer {
  switch result {
  case .supersededAfterMutation, .cancelledAfterMutation:
    return NativeFocusRecoveryTransfer(
      carried: carried ?? request,
      recovery: nil
    )
  case .cancelledAfterInputMutation:
    guard generationCurrent else {
      return NativeFocusRecoveryTransfer(carried: carried, recovery: nil)
    }
    return NativeFocusRecoveryTransfer(
      carried: nil,
      recovery: carried ?? request
    )
  case .frameSuperseded, .superseded, .cancelled, .failed,
    .failedAfterMutation:
    guard generationCurrent else {
      return NativeFocusRecoveryTransfer(carried: carried, recovery: nil)
    }
    return NativeFocusRecoveryTransfer(
      carried: nil,
      recovery: result == .failedAfterMutation
        ? carried ?? request
        : carried
    )
  case .completed, .completedWithoutMutation:
    guard generationCurrent else {
      return NativeFocusRecoveryTransfer(carried: carried, recovery: nil)
    }
    return NativeFocusRecoveryTransfer(carried: nil, recovery: nil)
  }
}

func resolvedNativeFocusResult(
  mutationApplied: Bool,
  generationCurrent: Bool,
  inputCurrent: Bool,
  cancelled: Bool,
  focusSucceeded: Bool
) -> NativeFocusResult {
  if mutationApplied && generationCurrent && !inputCurrent {
    return .cancelledAfterInputMutation
  }
  if mutationApplied && !generationCurrent {
    return .supersededAfterMutation
  }
  if mutationApplied && (cancelled || !generationCurrent || !inputCurrent) {
    return .cancelledAfterMutation
  }
  if !generationCurrent {
    return .superseded
  }
  if !cancelled && generationCurrent && inputCurrent {
    if focusSucceeded {
      return mutationApplied ? .completed : .completedWithoutMutation
    }
    return mutationApplied ? .failedAfterMutation : .failed
  }
  return .cancelled
}

func nativeFocusRecoveryRequestForCompletion(
  _ request: NativeFocusRecoveryRequest?,
  result: NativeFocusResult,
  explicitFallback: NativeFocusRecoveryFallback?
) -> NativeFocusRecoveryRequest? {
  guard let request else { return nil }
  let fallback = explicitFallback ?? request.fallback
  return NativeFocusRecoveryRequest(
    timestamp: request.timestamp,
    excludingWindowID: request.excludingWindowID,
    excludingProcessID: request.excludingProcessID,
    fallback: fallback,
    fallbackOnlyIfNoNewerInput:
      request.fallbackOnlyIfNoNewerInput
      || explicitFallback != nil
      || result == .failedAfterMutation
  )
}

func focusMutationStateAfterActivation(
  priorMutationApplied: Bool,
  activationSucceeded: Bool
) -> Bool {
  priorMutationApplied || activationSucceeded
}

func specificWindowFocusWriteIsRequired(
  requested: Bool,
  validatesCurrentFocus: Bool,
  targetIsFocused: Bool
) -> Bool {
  (requested || validatesCurrentFocus) && !targetIsFocused
}
