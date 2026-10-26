import AppKit
import CoreGraphics
import CoreImage
import DefiModel
import Foundation
import ScreenCaptureKit
import os

func overviewPreviewBlurFadeHeight(
  titleBandHeight: CGFloat,
  imageScale: CGFloat,
  imageHeight: CGFloat
) -> CGFloat {
  min(max((titleBandHeight + 20) * imageScale, 1), imageHeight)
}

// Shared so each derivation does not pay for a new Core Image context.
let overviewPreviewRenderingContext = CIContext(options: [.cacheIntermediates: false])

/// A small blurred copy of a shared window picture. Cards draw it over their title
/// band, masked to fade into the sharp picture, so the picture itself is never copied.
func overviewBlurredPreview(
  _ image: CGImage,
  context: CIContext = overviewPreviewRenderingContext
) -> CGImage? {
  let source = CIImage(cgImage: image)
  let scale = min(256 / max(source.extent.width, source.extent.height, 1), 1)
  let small = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
  let extent = small.extent.integral
  guard extent.width > 1, extent.height > 1 else { return nil }
  let blurred = small.clampedToExtent()
    .applyingGaussianBlur(sigma: max(extent.height * 0.04, 3)).cropped(to: extent)
  return context.createCGImage(blurred, from: extent)
}

func overviewPreviewOpacity(
  startedAt: TimeInterval?,
  now: TimeInterval,
  reduceMotion: Bool,
  duration: TimeInterval = 0.45
) -> Double {
  guard !reduceMotion, let startedAt, duration > 0 else { return 1 }
  let progress = min(max((now - startedAt) / duration, 0), 1)
  return progress * progress * (3 - 2 * progress)
}

public enum OverviewPreviewPermissionState: String, Sendable {
  case disabled
  case notDetermined = "not-determined"
  case granted
  case denied
}

// Workers may overlap image processing, but only one macOS capture/consent call
// may be outstanding. Cancellation does not dismiss a system consent dialog.
let overviewPreviewMaximumConcurrentCaptures = 2
let overviewCaptureLimiter = OverviewCaptureLimiter(limit: 1)
private let overviewCaptureLogger = Logger(subsystem: "com.qeude.defi", category: "overview-capture")

struct OverviewCaptureTimeoutError: Error {}

struct UncheckedSendable<Value>: @unchecked Sendable { let value: Value }

// A ScreenCaptureKit call that never returns would hold the single limiter slot until
// restart. Abandon it after the deadline so the next overview session can capture.
@MainActor
func withOverviewCaptureTimeout<Value>(
  seconds: Double = 5,
  _ operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
  let outcome: UncheckedSendable<Result<Value, Error>> = await withCheckedContinuation { continuation in
    let finished = OSAllocatedUnfairLock(initialState: false)
    @Sendable func finish(_ result: Result<Value, Error>) {
      let first = finished.withLock { done -> Bool in
        defer { done = true }
        return !done
      }
      if first { continuation.resume(returning: UncheckedSendable(value: result)) }
    }
    Task {
      do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
    }
    Task {
      try? await Task.sleep(for: .seconds(seconds))
      finish(.failure(OverviewCaptureTimeoutError()))
    }
  }
  return try outcome.value.get()
}

actor OverviewCaptureLimiter {
  private var available: Int
  private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
  private(set) var authorizationDeclined = false
  var waitingCount: Int { waiters.count }

  init(limit: Int = overviewPreviewMaximumConcurrentCaptures) { available = limit }

  @discardableResult
  func acquire() async -> Bool {
    guard !authorizationDeclined, !Task.isCancelled else { return false }
    if available > 0 {
      available -= 1
      return true
    }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: false) }
        else { waiters.append((id, continuation)) }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  func release(error: NSError? = nil) {
    if let error {
      overviewCaptureLogger.error("Capture failed: domain=\(error.domain, privacy: .public) code=\(error.code)")
      // SCStreamErrorUserDeclined: no background retry after denied direct access.
      // A deliberate daemon restart starts a new authorization attempt.
      if error.domain == SCStreamErrorDomain && error.code == -3801 {
        authorizationDeclined = true
        overviewCaptureLogger.notice("Capture suspended until restart after authorization refusal")
        for (_, waiter) in waiters { waiter.resume(returning: false) }
        waiters.removeAll()
      }
    }
    if waiters.isEmpty { available += 1 }
    else { waiters.removeFirst().1.resume(returning: true) }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(returning: false)
  }
}
