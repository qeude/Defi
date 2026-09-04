import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog


extension AXFocusWriter {
  func drain() {
    while true {
      lock.lock()
      guard let queued = pending else {
        running = false
        lock.unlock()
        return
      }
      pending = nil
      activeProcessID = queued.request.processID
      activeGeneration = queued.generation
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let request = queued.request
      guard isCurrent(queued) else {
        let generationCurrent = isCurrent(queued.generation)
        lock.lock()
        activeProcessID = nil
        activeGeneration = nil
        cancelledCount += 1
        lock.unlock()
        complete(
          queued,
          result: generationCurrent ? .cancelled : .superseded,
          generationCurrent: generationCurrent
        )
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
      if selectsSpecificWindow || request.validatesSpecificWindowFocus {
        selectsSpecificWindow = specificWindowFocusWriteIsRequired(
          requested: selectsSpecificWindow,
          validatesCurrentFocus: request.validatesSpecificWindowFocus,
          targetIsFocused: isTargetFocused(
            request.element,
            application: request.application
          )
        )
      }
      if selectsSpecificWindow {
        AXMessagingTimeoutAccess.shared.withTimeout(
          0.016,
          elements: [request.application, request.element]
        ) {
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
            AXMessagingTimeoutAccess.shared.withTimeout(
              0.05,
              elements: [request.application, request.element]
            ) {
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
            }
            cancelled = !isCurrent(queued)
          }
        }
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
        focusMutationApplied = focusMutationStateAfterActivation(
          priorMutationApplied: focusMutationApplied,
          activationSucceeded: activationSucceeded
        )
        activationDurationMS =
          (ProcessInfo.processInfo.systemUptime - activationStartedAt) * 1_000
      } else if activationRequired == nil {
        cancelled = true
      }
      if !cancelled,
        windowSelectionSucceeded,
        activationSucceeded,
        isCurrent(queued),
        inputGuardIsCurrent(request)
      {
        for element in request.foregroundWindowElements {
          guard isCurrent(queued), inputGuardIsCurrent(request) else {
            cancelled = true
            break
          }
          let raiseStartedAt = ProcessInfo.processInfo.systemUptime
          let outcome = performForegroundRaise(
            isCurrent: {
              isCurrent(queued) && inputGuardIsCurrent(request)
            },
            attempt: { timeout in
              AXMessagingTimeoutAccess.shared.withTimeout(
                timeout,
                elements: [element]
              ) {
                AXUIElementPerformAction(
                  element,
                  kAXRaiseAction as CFString
                )
              }
            }
          )
          raiseDurationMS +=
            (ProcessInfo.processInfo.systemUptime - raiseStartedAt) * 1_000
          retried = retried || outcome.retried
          if outcome.cancelled {
            cancelled = true
            break
          }
        }
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
      activeGeneration = nil
      lock.unlock()
      let generationCurrent = isCurrent(queued.generation)
      let inputCurrent = inputGuardIsCurrent(request)
        && !isExplicitlyCancelled(queued.generation)
      let focusSucceeded =
        windowSelectionSucceeded && activationSucceeded
      let result = resolvedNativeFocusResult(
        mutationApplied: focusMutationApplied,
        generationCurrent: generationCurrent,
        inputCurrent: inputCurrent,
        cancelled: cancelled,
        focusSucceeded: focusSucceeded
      )
      complete(
        queued,
        result: result,
        generationCurrent: generationCurrent
      )
    }
  }

  private func complete(
    _ queued: QueuedFocusRequest,
    result: NativeFocusResult,
    generationCurrent: Bool
  ) {
    lock.lock()
    explicitlyCancelledGenerations.remove(queued.generation)
    let explicitCancellationFallback = explicitCancellationFallbacks.removeValue(
      forKey: queued.generation
    )
    let recoveryResetGeneration = minimumRecoveryGeneration
    lock.unlock()
    if appliedRecoveryResetGeneration < recoveryResetGeneration {
      carriedFocusRecovery = nil
      appliedRecoveryResetGeneration = recoveryResetGeneration
    }
    let discardsRecovery = queued.generation < recoveryResetGeneration
    if discardsRecovery {
      carriedFocusRecovery = nil
      queued.completion(
        NativeFocusCompletion(result: result, recoveryRequest: nil)
      )
      return
    }
    let recoveryRequest = nativeFocusRecoveryRequestForCompletion(
      queued.request.recoveryRequest,
      result: result,
      explicitFallback: explicitCancellationFallback
    )
    let recoveryTransfer = transferredNativeFocusRecovery(
      carried: carriedFocusRecovery,
      request: recoveryRequest,
      result: result,
      generationCurrent: generationCurrent
    )
    carriedFocusRecovery = recoveryTransfer.carried
    queued.completion(
      NativeFocusCompletion(
        result: result,
        recoveryRequest: recoveryTransfer.recovery
      )
    )
  }

  private func isCurrent(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return latestGeneration == generation
  }

  private func isCurrent(_ queued: QueuedFocusRequest) -> Bool {
    lock.lock()
    let explicitlyCancelled = explicitlyCancelledGenerations.contains(
      queued.generation
    )
    lock.unlock()
    guard !explicitlyCancelled, isCurrent(queued.generation) else {
      return false
    }
    return inputGuardIsCurrent(queued.request)
  }

  private func isExplicitlyCancelled(_ generation: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return explicitlyCancelledGenerations.contains(generation)
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

  private func isTargetFocused(
    _ element: AXUIElement,
    application: AXUIElement
  ) -> Bool {
    AXMessagingTimeoutAccess.shared.withTimeout(
      0.016,
      elements: [application, element]
    ) {
      // AXMain is structural app state, not proof of keyboard focus. Apps such as
      // Kaku can leave a non-focused window main during rapid intra-app navigation.
      targetWindowFocusIsConfirmed(
        readBoolean(element, attribute: kAXFocusedAttribute)
      ) {
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
          application,
          kAXFocusedWindowAttribute as CFString,
          &focusedWindow
        ) == .success,
          let focusedWindow,
          CFGetTypeID(focusedWindow) == AXUIElementGetTypeID()
        else {
          return false
        }
        return CFEqual(focusedWindow, element)
      }
    }
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
