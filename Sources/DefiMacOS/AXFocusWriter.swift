import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

struct QueuedFocusRequest: @unchecked Sendable {
  let generation: UInt64
  let request: AsyncFocusRequest
  let completion: @Sendable (NativeFocusCompletion) -> Void
}

final class AXFocusWriter: @unchecked Sendable {
  let queue = DispatchQueue(
    label: "com.quentin.defi.ax-focus",
    qos: .userInitiated
  )
  let lock = NSLock()
  var pending: QueuedFocusRequest?
  var explicitlyCancelledGenerations = Set<UInt64>()
  var explicitCancellationFallbacks:
    [UInt64: NativeFocusRecoveryFallback] = [:]
  var activeProcessID: pid_t?
  var activeGeneration: UInt64?
  var needsRecoveryActivation = false
  var carriedFocusRecovery: NativeFocusRecoveryRequest?
  var latestGeneration: UInt64 = 0
  var minimumRecoveryGeneration: UInt64 = 0
  var appliedRecoveryResetGeneration: UInt64 = 0
  var running = false
  var lastDurationMS = 0.0
  var fastPathCount = 0
  var cancelledCount = 0
  var retryCount = 0
  var lastMainDurationMS = 0.0
  var lastRaiseDurationMS = 0.0
  var lastActivationDurationMS = 0.0

  @discardableResult
  func submit(
    _ request: AsyncFocusRequest,
    completion: @escaping @Sendable (NativeFocusCompletion) -> Void
  ) -> NativeFocusRequestID {
    lock.lock()
    let replaced = pending
    if replaced != nil {
      cancelledCount += 1
    }
    latestGeneration &+= 1
    let generation = latestGeneration
    pending = QueuedFocusRequest(
      generation: generation,
      request: request,
      completion: completion
    )
    let shouldStart = !running
    if shouldStart {
      running = true
    }
    if let replaced {
      explicitlyCancelledGenerations.remove(replaced.generation)
      explicitCancellationFallbacks.removeValue(forKey: replaced.generation)
    }
    lock.unlock()
    replaced?.completion(
      NativeFocusCompletion(result: .superseded, recoveryRequest: nil)
    )
    if shouldStart {
      queue.async { [self] in drain() }
    }
    return NativeFocusRequestID(rawValue: generation)
  }

  @discardableResult
  func cancel(
    _ requestID: NativeFocusRequestID,
    recoveryFallback: NativeFocusRecoveryFallback? = nil
  ) -> Bool {
    lock.lock()
    guard focusRequestCanBeCancelled(
      requestGeneration: requestID.rawValue,
      latestGeneration: latestGeneration,
      pendingGeneration: pending?.generation,
      activeGeneration: activeGeneration
    ) else {
      lock.unlock()
      return false
    }
    explicitlyCancelledGenerations.insert(requestID.rawValue)
    if let recoveryFallback {
      explicitCancellationFallbacks[requestID.rawValue] = recoveryFallback
    }
    let replaced = pending?.generation == requestID.rawValue ? pending : nil
    if replaced != nil {
      cancelledCount += 1
    }
    lock.unlock()
    return true
  }

  func invalidate() {
    lock.lock()
    let replaced = pending
    pending = nil
    latestGeneration &+= 1
    minimumRecoveryGeneration = latestGeneration
    if let replaced {
      explicitlyCancelledGenerations.remove(replaced.generation)
      explicitCancellationFallbacks.removeValue(forKey: replaced.generation)
    }
    if replaced != nil {
      cancelledCount += 1
    }
    lock.unlock()
    replaced?.completion(
      NativeFocusCompletion(result: .superseded, recoveryRequest: nil)
    )
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

}
