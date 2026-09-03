import CoreGraphics
import CoreImage
import DefiModel
import Foundation
import ScreenCaptureKit

func overviewPreviewBlurFadeHeight(
  titleBandHeight: CGFloat,
  imageScale: CGFloat,
  imageHeight: CGFloat
) -> CGFloat {
  min(max((titleBandHeight + 20) * imageScale, 1), imageHeight)
}

func progressivelyBlurredOverviewPreview(
  _ image: CGImage,
  fadeHeight requestedFadeHeight: CGFloat,
  context: CIContext = CIContext(options: [.cacheIntermediates: false])
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
  guard let output = blur.outputImage?.cropped(to: extent) else { return nil }
  return context.createCGImage(output, from: extent)
}

func overviewPreviewOpacity(
  startedAt: TimeInterval?,
  now: TimeInterval,
  reduceMotion: Bool,
  duration: TimeInterval = 0.32
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

func runOverviewPreviewCaptures(
  _ requests: [OverviewPreviewRequest],
  maximumConcurrent: Int = 2,
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
      results.append(result)
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
  desktops desktopRequests: [OverviewDesktopCaptureRequest]
) async -> OverviewCaptureResults {
  let renderingContext = CIContext(options: [.cacheIntermediates: false])
  defer { renderingContext.clearCaches() }
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(
      true,
      onScreenWindowsOnly: false
    )
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
      if let image = try? await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      ) {
        desktops[request.monitorID] = image
      }
    }
    let windows = Dictionary(
      uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
    )
    let batch = OverviewScreenCaptureBatch(
      windows: windows,
      renderingContext: renderingContext
    )
    let previews = await runOverviewPreviewCaptures(requests) { request in
      await batch.capture(request)
    }
    return OverviewCaptureResults(previews: previews, desktops: desktops)
  } catch {
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

  init(windows: [CGWindowID: SCWindow], renderingContext: CIContext) {
    self.windows = windows
    self.renderingContext = renderingContext
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
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(desktopIndependentWindow: window),
        configuration: configuration
      )
      let renderingContext = renderingContext
      let styledImage = await Task.detached(priority: .userInitiated) {
        progressivelyBlurredOverviewPreview(
          image,
          fadeHeight: CGFloat(request.blurFadeHeight),
          context: renderingContext
        ) ?? image
      }.value
      return OverviewPreviewCaptureResult(request: request, image: styledImage)
    } catch {
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }
  }
}

func overviewPreviewResultIsCurrent(
  _ result: OverviewPreviewCaptureResult,
  generation: UInt64,
  currentGeneration: UInt64,
  currentRequest: OverviewPreviewRequest?,
  currentAppID: String?
) -> Bool {
  overviewPreviewRequestIsCurrent(
    result.request,
    generation: generation,
    currentGeneration: currentGeneration,
    currentRequest: currentRequest,
    currentAppID: currentAppID
  )
    && (result.image.map { $0.width > 1 && $0.height > 1 } ?? false)
}

func overviewPreviewRequestIsCurrent(
  _ request: OverviewPreviewRequest,
  generation: UInt64,
  currentGeneration: UInt64,
  currentRequest: OverviewPreviewRequest?,
  currentAppID: String?
) -> Bool {
  generation == currentGeneration
    && currentRequest == request
    && currentAppID == request.expectedAppID
}
