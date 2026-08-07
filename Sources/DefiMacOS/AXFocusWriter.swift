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
}

public enum NativeFocusResult: Equatable, Sendable {
  case completed
  case cancelled
  case cancelledAfterMutation
  case failed
  case failedAfterMutation
}

func resolvedNativeFocusResult(
  mutationApplied: Bool,
  generationCurrent: Bool,
  inputCurrent: Bool,
  cancelled: Bool,
  focusSucceeded: Bool
) -> NativeFocusResult {
  if mutationApplied && (cancelled || !generationCurrent || !inputCurrent) {
    return .cancelledAfterMutation
  }
  if !cancelled && generationCurrent && inputCurrent {
    if focusSucceeded {
      return .completed
    }
    return mutationApplied ? .failedAfterMutation : .failed
  }
  return .cancelled
}

private struct QueuedFocusRequest: @unchecked Sendable {
  let generation: UInt64
  let request: AsyncFocusRequest
  let completion: @Sendable (NativeFocusResult) -> Void
}

final class AXFocusWriter: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-focus",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var pending: QueuedFocusRequest?
  private var activeProcessID: pid_t?
  private var needsRecoveryActivation = false
  private var latestGeneration: UInt64 = 0
  private var running = false
  private var lastDurationMS = 0.0
  private var fastPathCount = 0
  private var cancelledCount = 0
  private var retryCount = 0
  private var lastMainDurationMS = 0.0
  private var lastRaiseDurationMS = 0.0
  private var lastActivationDurationMS = 0.0

  func submit(
    _ request: AsyncFocusRequest,
    completion: @escaping @Sendable (NativeFocusResult) -> Void
  ) {
    lock.lock()
    let replaced = pending
    if replaced != nil {
      cancelledCount += 1
    }
    latestGeneration &+= 1
    pending = QueuedFocusRequest(
      generation: latestGeneration,
      request: request,
      completion: completion
    )
    let shouldStart = !running
    if shouldStart {
      running = true
    }
    lock.unlock()
    replaced?.completion(.cancelled)
    if shouldStart {
      queue.async { [self] in drain() }
    }
  }

  var isBusy: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running || pending != nil
  }

  func hasInFlightRequest(forDifferentProcess processID: pid_t) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return activeProcessID.map { $0 != processID } == true
      || pending.map { $0.request.processID != processID } == true
  }

  var durationMS: Double {
    lock.lock()
    defer { lock.unlock() }
    return lastDurationMS
  }

  var performance:
    (
      durationMS: Double,
      fastPaths: Int,
      cancelled: Int,
      retries: Int,
      mainDurationMS: Double,
      raiseDurationMS: Double,
      activationDurationMS: Double
    )
  {
    lock.lock()
    defer { lock.unlock() }
    return (
      lastDurationMS,
      fastPathCount,
      cancelledCount,
      retryCount,
      lastMainDurationMS,
      lastRaiseDurationMS,
      lastActivationDurationMS
    )
  }

  private func drain() {
    while true {
      lock.lock()
      guard let queued = pending else {
        running = false
        lock.unlock()
        return
      }
      pending = nil
      activeProcessID = queued.request.processID
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let request = queued.request
      guard isCurrent(queued) else {
        lock.lock()
        activeProcessID = nil
        cancelledCount += 1
        lock.unlock()
        queued.completion(.cancelled)
        continue
      }
      var usedFastPath = false
      var cancelled = false
      var retried = false
      var mainDurationMS = 0.0
      var raiseDurationMS = 0.0
      var activationDurationMS = 0.0
      var focusMutationApplied = false
      var windowSelectionSucceeded = false
      var selectsSpecificWindow = request.selectsSpecificWindow
      if !selectsSpecificWindow, request.validatesSpecificWindowFocus {
        selectsSpecificWindow = !isTargetFocused(request.element)
      }
      if selectsSpecificWindow {
        AXUIElementSetMessagingTimeout(request.application, 0.016)
        AXUIElementSetMessagingTimeout(request.element, 0.016)
        let mainStartedAt = ProcessInfo.processInfo.systemUptime
        var mainResult = AXUIElementSetAttributeValue(
          request.element,
          kAXMainAttribute as CFString,
          kCFBooleanTrue
        )
        focusMutationApplied = mainResult == .success
        windowSelectionSucceeded = mainResult == .success
        mainDurationMS =
          (ProcessInfo.processInfo.systemUptime - mainStartedAt) * 1_000
        cancelled = !isCurrent(queued)
        var raiseResult = AXError.cannotComplete
        if !cancelled, mainResult != .success {
          let raiseStartedAt = ProcessInfo.processInfo.systemUptime
          raiseResult = AXUIElementPerformAction(
            request.element,
            kAXRaiseAction as CFString
          )
          focusMutationApplied =
            focusMutationApplied
            || raiseResult == .success
          windowSelectionSucceeded =
            windowSelectionSucceeded
            || raiseResult == .success
          raiseDurationMS =
            (ProcessInfo.processInfo.systemUptime - raiseStartedAt) * 1_000
        }
        cancelled = cancelled || !isCurrent(queued)
        if !cancelled,
          mainResult != .success && raiseResult != .success
        {
          retried = true
          AXUIElementSetMessagingTimeout(request.application, 0.05)
          AXUIElementSetMessagingTimeout(request.element, 0.05)
          let retryMainStartedAt = ProcessInfo.processInfo.systemUptime
          mainResult = AXUIElementSetAttributeValue(
            request.element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
          )
          focusMutationApplied =
            focusMutationApplied
            || mainResult == .success
          windowSelectionSucceeded =
            windowSelectionSucceeded
            || mainResult == .success
          mainDurationMS +=
            (ProcessInfo.processInfo.systemUptime - retryMainStartedAt) * 1_000
          if isCurrent(queued), mainResult != .success {
            let retryRaiseStartedAt = ProcessInfo.processInfo.systemUptime
            raiseResult = AXUIElementPerformAction(
              request.element,
              kAXRaiseAction as CFString
            )
            focusMutationApplied =
              focusMutationApplied
              || raiseResult == .success
            windowSelectionSucceeded =
              windowSelectionSucceeded
              || raiseResult == .success
            raiseDurationMS +=
              (ProcessInfo.processInfo.systemUptime - retryRaiseStartedAt) * 1_000
          }
          cancelled = !isCurrent(queued)
        }
        resetTimeouts(request)
      } else {
        usedFastPath = true
        windowSelectionSucceeded = true
      }
      var activationAttempted = false
      var activationSucceeded = true
      let activationRequired =
        cancelled || !isCurrent(queued)
        ? nil
        : activationRequirement(
          requested: request.activatesApplication,
          generation: queued.generation
        )
      if activationRequired == true {
        activationAttempted = true
        activationSucceeded = false
        let activationStartedAt = ProcessInfo.processInfo.systemUptime
        let system = AXUIElementCreateSystemWide()
        let activationResult = AXUIElementSetAttributeValue(
          system,
          kAXFocusedApplicationAttribute as CFString,
          request.application
        )
        if activationResult == .success {
          activationSucceeded = true
        } else if isCurrent(queued) {
          activationSucceeded =
            NSRunningApplication(processIdentifier: request.processID)?
            .activate() == true
        }
        focusMutationApplied = true
        activationDurationMS =
          (ProcessInfo.processInfo.systemUptime - activationStartedAt) * 1_000
      } else if activationRequired == nil {
        cancelled = true
      }
      if activationAttempted, !isCurrent(queued) {
        markRecoveryActivationNeeded()
        cancelled = true
      }
      let durationMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      lock.lock()
      lastDurationMS = durationMS
      if usedFastPath { fastPathCount += 1 }
      if cancelled { cancelledCount += 1 }
      if retried { retryCount += 1 }
      lastMainDurationMS = mainDurationMS
      lastRaiseDurationMS = raiseDurationMS
      lastActivationDurationMS = activationDurationMS
      activeProcessID = nil
      lock.unlock()
      let generationCurrent = isCurrent(queued.generation)
      let inputCurrent = inputGuardIsCurrent(request)
      let focusSucceeded =
        windowSelectionSucceeded && activationSucceeded
      queued.completion(
        resolvedNativeFocusResult(
          mutationApplied: focusMutationApplied,
          generationCurrent: generationCurrent,
          inputCurrent: inputCurrent,
          cancelled: cancelled,
          focusSucceeded: focusSucceeded
        )
      )
    }
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  private func isCurrent(_ queued: QueuedFocusRequest) -> Bool {
    guard isCurrent(queued.generation) else { return false }
    return inputGuardIsCurrent(queued.request)
  }

  private func inputGuardIsCurrent(_ request: AsyncFocusRequest) -> Bool {
    guard let inputGuard = request.inputGuard else { return true }
    return guardedFocusIsCurrent(
      latestInputTimestamp: inputGuard.tracker.latestEventTimestamp,
      maximumInputTimestamp: inputGuard.maximumTimestamp
    )
  }

  private func activationRequirement(
    requested: Bool,
    generation: UInt64
  ) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    guard latestGeneration == generation else { return nil }
    let required = requested || needsRecoveryActivation
    needsRecoveryActivation = false
    return required
  }

  private func markRecoveryActivationNeeded() {
    lock.lock()
    needsRecoveryActivation = true
    lock.unlock()
  }

  private func resetTimeouts(_ request: AsyncFocusRequest) {
    AXUIElementSetMessagingTimeout(request.element, 0)
    AXUIElementSetMessagingTimeout(request.application, 0)
  }

  private func isTargetFocused(_ element: AXUIElement) -> Bool {
    AXUIElementSetMessagingTimeout(element, 0.016)
    defer { AXUIElementSetMessagingTimeout(element, 0) }
    return readBoolean(element, attribute: kAXFocusedAttribute) == true
      || readBoolean(element, attribute: kAXMainAttribute) == true
  }

  private func readBoolean(
    _ element: AXUIElement,
    attribute: String
  ) -> Bool? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &rawValue
      ) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == CFBooleanGetTypeID()
    else {
      return nil
    }
    return CFBooleanGetValue((rawValue as! CFBoolean))
  }
}
