import CoreGraphics
import CoreImage
import DefiModel
import Foundation
import ScreenCaptureKit
import os

// Small placeholders survive between sessions; full-resolution captures stay session-local.
func compactOverviewPreview(_ image: CGImage) -> CGImage? {
  let scale = min(512.0 / Double(max(image.width, image.height)), 1)
  let width = max(Int(Double(image.width) * scale), 1)
  let height = max(Int(Double(image.height) * scale), 1)
  guard let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  ) else { return nil }
  context.interpolationQuality = .medium
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  return context.makeImage()
}

func overviewPreviewBlurFadeHeight(
  titleBandHeight: CGFloat,
  imageScale: CGFloat,
  imageHeight: CGFloat
) -> CGFloat {
  min(max((titleBandHeight + 20) * imageScale, 1), imageHeight)
}

// Shared so each capture batch does not pay for a new Core Image context.
let overviewPreviewRenderingContext = CIContext(options: [.cacheIntermediates: false])

func progressivelyBlurredOverviewPreview(
  _ image: CGImage,
  fadeHeight requestedFadeHeight: CGFloat,
  context: CIContext = overviewPreviewRenderingContext
) -> CGImage? {
  let source = CIImage(cgImage: image)
  let extent = source.extent
  guard extent.width > 1, extent.height > 1,
    let gradient = CIFilter(name: "CISmoothLinearGradient"),
    let blur = CIFilter(name: "CIMaskedVariableBlur")
  else { return nil }

  let fadeHeight = min(max(requestedFadeHeight, 1), extent.height)
  gradient.setValue(
    CIVector(x: extent.midX, y: extent.maxY),
    forKey: "inputPoint0"
  )
  gradient.setValue(
    CIVector(x: extent.midX, y: extent.maxY - fadeHeight),
    forKey: "inputPoint1"
  )
  gradient.setValue(CIColor.white, forKey: "inputColor0")
  gradient.setValue(CIColor.black, forKey: "inputColor1")
  guard let mask = gradient.outputImage?.cropped(to: extent) else { return nil }

  blur.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
  blur.setValue(mask, forKey: "inputMask")
  blur.setValue(min(max(extent.height * 0.04, 10), 24), forKey: kCIInputRadiusKey)
  // Only the title band is blurred; the rest of the preview is composited unchanged.
  let band = CGRect(
    x: extent.minX, y: extent.maxY - fadeHeight, width: extent.width, height: fadeHeight
  )
  guard let output = blur.outputImage?.cropped(to: band).composited(over: source)
    .cropped(to: extent)
  else { return nil }
  return context.createCGImage(output, from: extent)
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

func overviewCaptureBatchNeeded(
  previewRequestCount: Int,
  hasPendingDesktopCapture: Bool
) -> Bool {
  previewRequestCount > 0 || hasPendingDesktopCapture
}

func overviewRecordedDesktopCaptureMonitorIDs(
  existing: Set<MonitorID>,
  requested: Set<MonitorID>,
  captured: Set<MonitorID>
) -> Set<MonitorID> {
  existing.union(captured.intersection(requested))
}

func overviewDesktopCaptureRetryNeeded(
  requested: Set<MonitorID>,
  captured: Set<MonitorID>
) -> Bool {
  !requested.isSubset(of: captured)
}

struct OverviewPreviewRequest: Equatable, Sendable {
  let windowID: WindowID
  let expectedAppID: String
  let width: Int
  let height: Int
  let blurFadeHeight: Int
}

struct OverviewPreviewCaptureResult: Sendable {
  let request: OverviewPreviewRequest
  let image: CGImage?
  var rememberedImage: CGImage? = nil
}

struct OverviewDesktopCaptureRequest: Sendable {
  let monitorID: MonitorID
  let displayID: CGDirectDisplayID
  let width: Int
  let height: Int
}

struct OverviewCaptureResults: Sendable {
  let previews: [OverviewPreviewCaptureResult]
  let desktops: [MonitorID: CGImage]
}

func overviewPreviewCacheCanStore(
  windowID: WindowID,
  byteCost: Int,
  currentByteCosts: [WindowID: Int],
  maximumBytes: Int
) -> Bool {
  guard byteCost > 0, byteCost <= maximumBytes else { return false }
  let bytesWithoutExisting = currentByteCosts.values.reduce(0, +)
    - (currentByteCosts[windowID] ?? 0)
  return bytesWithoutExisting <= maximumBytes - byteCost
}

func overviewPreviewOwnerMatches(
  expectedAppID: String,
  capturedAppID: String?
) -> Bool {
  capturedAppID == expectedAppID
}

// Workers may overlap image processing, but only one macOS capture/consent call
// may be outstanding. Cancellation does not dismiss a system consent dialog.
let overviewPreviewMaximumConcurrentCaptures = 2
let overviewCaptureLimiter = OverviewCaptureLimiter(limit: 1)
private let overviewCaptureLogger = Logger(subsystem: "com.quentin.defi", category: "overview-capture")

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

// Capping width and height independently distorts the aspect of large cards (full-width
// windows), so the capture would letterbox and the card would show an empty band.
func overviewPreviewPixelSize(
  cardWidth: Double,
  cardHeight: Double,
  scale: Double,
  maximumWidth: Double = 1_024,
  maximumHeight: Double = 768
) -> (width: Int, height: Int) {
  let width = max(cardWidth * scale, 1)
  let height = max(cardHeight * scale, 1)
  let fit = min(maximumWidth / width, maximumHeight / height, 1)
  return (
    max(Int((width * fit).rounded(.up)), 32),
    max(Int((height * fit).rounded(.up)), 24)
  )
}

struct OverviewPreviewCandidate {
  let request: OverviewPreviewRequest
  let monitorID: MonitorID
  let centerX: Double
  let centerY: Double
}

// Bound the whole decoded batch, including offscreen cards, rather than only
// limiting each image. Preserve every preview at lower resolution when needed.
func boundedOverviewPreviewRequests(_ requests: [OverviewPreviewRequest],
  maximumBytes: Int = 128 * 1024 * 1024) -> [OverviewPreviewRequest] {
  let total = requests.reduce(0.0) { $0 + Double($1.width) * Double($1.height) * 4 }
  guard maximumBytes > 0, total > 0 else { return [] }
  let scale = min(sqrt(Double(maximumBytes) / total), 1)
  var remaining = maximumBytes
  return requests.compactMap { request in
    let width = max(Int(Double(request.width) * scale), 1)
    let height = max(Int(Double(request.height) * scale), 1)
    let bytes = width * height * 4
    guard bytes <= remaining else { return nil }
    remaining -= bytes
    return OverviewPreviewRequest(windowID: request.windowID, expectedAppID: request.expectedAppID,
      width: width, height: height,
      blurFadeHeight: max(Int(Double(request.blurFadeHeight) * scale), 1))
  }
}

// Selected monitor first, nearest to the anchor outward; other monitors keep their order.
func overviewPreviewCaptureOrder(
  _ candidates: [OverviewPreviewCandidate],
  selectedMonitorID: MonitorID?,
  anchor: (x: Double, y: Double)?
) -> [OverviewPreviewRequest] {
  func key(_ candidate: OverviewPreviewCandidate) -> (Int, Double) {
    let monitorRank = candidate.monitorID == selectedMonitorID ? 0 : 1
    // Coordinates are panel-local, so distance is only meaningful on the anchor's monitor.
    guard monitorRank == 0, let anchor else { return (monitorRank, 0) }
    let dx = candidate.centerX - anchor.x
    let dy = candidate.centerY - anchor.y
    return (monitorRank, dx * dx + dy * dy)
  }
  var seen = Set<WindowID>()
  return candidates.enumerated()
    .sorted { lhs, rhs in
      let (l, r) = (key(lhs.element), key(rhs.element))
      return l != r ? l < r : lhs.offset < rhs.offset
    }
    .map(\.element.request)
    .filter { seen.insert($0.windowID).inserted }
}

func runOverviewPreviewCaptures(
  _ requests: [OverviewPreviewRequest],
  maximumConcurrent: Int = overviewPreviewMaximumConcurrentCaptures,
  retainResults: Bool = true,
  completed: @escaping @Sendable (OverviewPreviewCaptureResult) async -> Void = { _ in },
  capture: @escaping @Sendable (OverviewPreviewRequest) async
    -> OverviewPreviewCaptureResult
) async -> [OverviewPreviewCaptureResult] {
  guard !requests.isEmpty else { return [] }
  let limit = max(min(maximumConcurrent, requests.count), 1)
  return await withTaskGroup(of: (Int, OverviewPreviewCaptureResult).self) { group in
    var nextIndex = 0
    for _ in 0..<limit {
      let index = nextIndex
      nextIndex += 1
      group.addTask {
        (index, await capture(requests[index]))
      }
    }
    var results: [(Int, OverviewPreviewCaptureResult)] = []
    while let result = await group.next() {
      if retainResults { results.append(result) }
      await completed(result.1)
      guard !Task.isCancelled else {
        group.cancelAll()
        break
      }
      if nextIndex < requests.count {
        let index = nextIndex
        nextIndex += 1
        group.addTask {
          (index, await capture(requests[index]))
        }
      }
    }
    return results.sorted { $0.0 < $1.0 }.map(\.1)
  }
}

@MainActor
func captureOverviewImages(
  previews requests: [OverviewPreviewRequest],
  desktops desktopRequests: [OverviewDesktopCaptureRequest],
  previewCompleted: @escaping @MainActor @Sendable (OverviewPreviewCaptureResult) -> Void
) async -> OverviewCaptureResults {
  let renderingContext = overviewPreviewRenderingContext
  // Old sessions may still be inside a non-cancellable macOS capture. Share
  // slots across sessions rather than multiplying WindowServer work on reopen.
  let limiter = overviewCaptureLimiter
  do {
    guard await limiter.acquire() else { return OverviewCaptureResults(previews: [], desktops: [:]) }
    let content: SCShareableContent
    do {
      try Task.checkCancellation()
      content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    } catch {
      await limiter.release(error: error is CancellationError ? nil : error as NSError)
      throw error
    }
    await limiter.release()
    // Desktop backgrounds capture alongside window previews instead of ahead of them.
    let desktopTask = Task { @MainActor in
      var desktops: [MonitorID: CGImage] = [:]
      for request in desktopRequests where !Task.isCancelled {
        guard let display = content.displays.first(where: {
          $0.displayID == request.displayID
        }) else { continue }
        let filter = SCContentFilter(
          display: display,
          excludingWindows: content.windows
        )
        filter.includeMenuBar = false
        let configuration = SCStreamConfiguration()
        configuration.width = request.width
        configuration.height = request.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        guard await limiter.acquire() else { break }
        // A worker cancelled while queued gives its slot back without capturing.
        guard !Task.isCancelled else {
          await limiter.release()
          break
        }
        do {
          let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
          await limiter.release()
          desktops[request.monitorID] = image
        } catch {
          await limiter.release(error: error as NSError)
        }
      }
      return desktops
    }
    let windows = Dictionary(
      uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
    )
    let batch = OverviewScreenCaptureBatch(
      windows: windows,
      renderingContext: renderingContext,
      limiter: limiter
    )
    return await withTaskCancellationHandler {
      let previews = await runOverviewPreviewCaptures(requests, retainResults: false, completed: { result in
        await previewCompleted(result)
      }) { request in
        await batch.capture(request)
      }
      let desktops = await desktopTask.value
      return OverviewCaptureResults(previews: previews, desktops: desktops)
    } onCancel: {
      desktopTask.cancel()
    }
  } catch {
    for request in requests where !Task.isCancelled {
      previewCompleted(OverviewPreviewCaptureResult(request: request, image: nil))
    }
    return OverviewCaptureResults(
      previews: requests.map {
        OverviewPreviewCaptureResult(request: $0, image: nil)
      },
      desktops: [:]
    )
  }
}

@MainActor
private final class OverviewScreenCaptureBatch {
  private let windows: [CGWindowID: SCWindow]
  private let renderingContext: CIContext
  private let limiter: OverviewCaptureLimiter

  init(
    windows: [CGWindowID: SCWindow],
    renderingContext: CIContext,
    limiter: OverviewCaptureLimiter
  ) {
    self.windows = windows
    self.renderingContext = renderingContext
    self.limiter = limiter
  }

  func capture(
    _ request: OverviewPreviewRequest
  ) async -> OverviewPreviewCaptureResult {
    guard !Task.isCancelled,
      let windowID = CGWindowID(exactly: request.windowID.rawValue),
      let window = windows[windowID],
      overviewPreviewOwnerMatches(
        expectedAppID: request.expectedAppID,
        capturedAppID: window.owningApplication?.bundleIdentifier
      )
    else {
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }
    let configuration = SCStreamConfiguration()
    configuration.width = request.width
    configuration.height = request.height
    configuration.showsCursor = false
    configuration.capturesAudio = false
    do {
      guard await limiter.acquire() else {
        return OverviewPreviewCaptureResult(request: request, image: nil)
      }
      guard !Task.isCancelled else {
        await limiter.release()
        return OverviewPreviewCaptureResult(request: request, image: nil)
      }
      let image: CGImage
      do {
        image = try await SCScreenshotManager.captureImage(
          contentFilter: SCContentFilter(desktopIndependentWindow: window),
          configuration: configuration
        )
      } catch {
        await limiter.release(error: error as NSError)
        throw error
      }
      await limiter.release()
      let renderingContext = renderingContext
      return await Task.detached(priority: .userInitiated) {
        let styledImage = progressivelyBlurredOverviewPreview(
          image,
          fadeHeight: CGFloat(request.blurFadeHeight),
          context: renderingContext
        ) ?? image
        return OverviewPreviewCaptureResult(
          request: request, image: styledImage,
          rememberedImage: compactOverviewPreview(styledImage)
        )
      }.value
    } catch {
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }
  }
}

func overviewPreviewRequestIsCurrent(
  _ request: OverviewPreviewRequest,
  generation: UInt64,
  currentGeneration: UInt64,
  currentRequest: OverviewPreviewRequest?,
  currentAppID: String?
) -> Bool {
  generation == currentGeneration
    && currentRequest?.windowID == request.windowID
    && currentAppID == request.expectedAppID
}
