import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import DefiCore
import DefiModel
import IOSurface
import ScreenCaptureKit

// Experimental public-API path. Conservative screenshot/renderer overlap budget.
// No persistent streams, bitmap copies or frame history.
let overviewSurfacePoolBudget = 256 * 1_024 * 1_024

struct OverviewSurfaceRequest: Equatable {
  let windowID: WindowID
  let appID: String
  let processID: Int32
  let width: Int
  let height: Int

  var estimatedPoolBytes: Int {
    // Four NV12 buffers, including row/height alignment allowance. GPU renderer
    // allocations are additional and must be measured separately.
    ((width + 255) / 256 * 256) * ((height + 15) / 16 * 16) * 6
  }
}

func overviewSurfaceRequestsFit(_ requests: [OverviewSurfaceRequest]) -> Bool {
  requests.reduce(0) { $0 + $1.estimatedPoolBytes } <= overviewSurfacePoolBudget
}

func overviewReadySurfaceIDs(requested: Set<WindowID>, captured: Set<WindowID>,
  displayReady: Set<WindowID>) -> Set<WindowID> {
  requested.intersection(captured).intersection(displayReady)
}

struct OverviewSurfaceFrame {
  // Keep the buffer alive while its surface is assigned to a layer.
  let buffer: CVPixelBuffer
  let sourceSize: CGSize
  var surface: IOSurface? { CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() }
  var width: Int { CVPixelBufferGetWidth(buffer) }
  var height: Int { CVPixelBufferGetHeight(buffer) }
}

func overviewSurfaceMatchesNativeSize(source: CGSize, native: Rect) -> Bool {
  source.width.isFinite && source.height.isFinite
    && abs(source.width - native.width) < 3
    && abs(source.height - native.height) < 3
}

// One-shot samples only: no persistent capture sessions or per-frame history.
@MainActor
final class OverviewSurfaceCapture {
  static let shared = OverviewSurfaceCapture()
  private struct Capture {
    let request: OverviewSurfaceRequest
    let frame: OverviewSurfaceFrame
  }
  private var captures: [WindowID: Capture] = [:]
  private var displayLayers: [WindowID: AVSampleBufferDisplayLayer] = [:]
  private var requested: [OverviewSurfaceRequest] = []
  private var desiredRequests: [OverviewSurfaceRequest] = []
  private var preparation: Task<Void, Never>?
  private var deferredPreparation: Task<Void, Never>?
  private var pendingRequests: [OverviewSurfaceRequest]?
  private var preparationDeadline: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var lastPreparationAt: TimeInterval = -.infinity
  private var failedRequests: [OverviewSurfaceRequest] = []
  private(set) var state = "disabled"
  var streamCount: Int { 0 }
  // Conservative allowance for screenshot/renderer overlap, not total GPU RAM.
  var estimatedPoolBytes: Int { captures.values.reduce(0) { $0 + $1.request.estimatedPoolBytes } }

  func prepare(_ requests: [OverviewSurfaceRequest], enabled: Bool) {
    guard enabled, CGPreflightScreenCaptureAccess() else {
      stop(state: enabled ? "permission" : "disabled"); return
    }
    guard !requests.isEmpty, overviewSurfaceRequestsFit(requests) else {
      stop(state: requests.isEmpty ? "empty" : "budget"); return
    }
    desiredRequests = requests
    let desired = Dictionary(uniqueKeysWithValues: requests.map { ($0.windowID, $0) })
    captures = captures.filter { desired[$0.key] == $0.value.request }
    displayLayers = displayLayers.filter { captures[$0.key] != nil }
    state = captures.count == requests.count ? "ready" : "warming"
    let now = CACurrentMediaTime()
    if requested == requests {
      pendingRequests = nil
      deferredPreparation?.cancel(); deferredPreparation = nil
      if preparation != nil { return }
      if failedRequests == requests && now - lastPreparationAt < 5 { return }
    }
    if preparation != nil || now - lastPreparationAt < 1 {
      pendingRequests = requests
      if deferredPreparation == nil {
        let delay = max(0.1, 1 - (now - lastPreparationAt))
        deferredPreparation = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(delay)) } catch { return }
          guard let self, let latest = pendingRequests else { return }
          pendingRequests = nil; deferredPreparation = nil
          prepare(latest, enabled: true)
        }
      }
      return
    }
    pendingRequests = nil
    deferredPreparation?.cancel(); deferredPreparation = nil
    generation &+= 1
    let token = generation
    preparation?.cancel()
    preparationDeadline?.cancel()
    preparationDeadline = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, generation == token, preparation != nil else { return }
      generation &+= 1
      preparation?.cancel(); preparation = nil
      failedRequests = requests; state = "timeout"
      preparationDeadline = nil
    }
    requested = requests
    lastPreparationAt = now
    preparation = Task { [weak self] in
      guard let self else { return }
      do {
        guard await overviewCaptureLimiter.acquire() else { throw SurfaceCaptureError.captureUnavailable }
        let content: SCShareableContent
        do {
          try Task.checkCancellation()
          content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
          await overviewCaptureLimiter.release(error: error is CancellationError ? nil : error as NSError)
          throw error
        }
        await overviewCaptureLimiter.release()
        for request in requests {
          guard !Task.isCancelled, generation == token else { return }
          guard let window = content.windows.first(where: {
            UInt64($0.windowID) == request.windowID.rawValue
              && $0.owningApplication?.bundleIdentifier == request.appID
              && $0.owningApplication?.processID == request.processID
          }) else { throw SurfaceCaptureError.missingWindow }
          let config = SCStreamConfiguration()
          config.width = request.width; config.height = request.height
          config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
          config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
          config.showsCursor = false; config.capturesAudio = false
          config.ignoreShadowsSingleWindow = true
          guard await overviewCaptureLimiter.acquire() else { throw SurfaceCaptureError.captureUnavailable }
          guard !Task.isCancelled, generation == token else {
            await overviewCaptureLimiter.release()
            return
          }
          let sample: CMSampleBuffer
          do {
            sample = try await SCScreenshotManager.captureSampleBuffer(
              contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
          } catch {
            await overviewCaptureLimiter.release(error: error as NSError)
            throw error
          }
          await overviewCaptureLimiter.release()
          guard !Task.isCancelled, generation == token else { return }
          guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw SurfaceCaptureError.missingPixels
          }
          let frame = OverviewSurfaceFrame(buffer: buffer, sourceSize: window.frame.size)
          guard frame.surface != nil, frame.width == request.width, frame.height == request.height else {
            throw SurfaceCaptureError.missingPixels
          }
          // Decode the replacement separately: warming must leave the currently
          // usable layer intact if opening cancels this refresh.
          let layer = AVSampleBufferDisplayLayer()
          layer.videoGravity = .resize
          guard enqueueWindowSurface(frame, on: layer) else { throw SurfaceCaptureError.missingPixels }
          for _ in 0..<30 where !layer.isReadyForDisplay {
            try await Task.sleep(for: .milliseconds(10))
          }
          guard !Task.isCancelled, generation == token else { return }
          guard layer.isReadyForDisplay else { throw SurfaceCaptureError.missingPixels }
          guard desiredRequests.contains(request) else { continue }
          captures[request.windowID] = Capture(request: request, frame: frame)
          displayLayers[request.windowID] = layer
        }
        guard generation == token else { return }
        preparationDeadline?.cancel(); preparationDeadline = nil
        preparation = nil; failedRequests = []
        state = captures.count == desiredRequests.count ? "ready" : "warming"
        if state == "warming" {
          // A skipped request may have become desired again while another was capturing.
          prepare(desiredRequests, enabled: true)
        }
      } catch {
        guard generation == token else { return }
        preparationDeadline?.cancel(); preparationDeadline = nil
        preparation = nil; failedRequests = requests
        state = captures.isEmpty ? "failed" : "partial"
      }
    }
  }

  // An opening scene owns one fixed image set, preventing refresh swaps during zoom.
  func freeze() {
    deferredPreparation?.cancel(); deferredPreparation = nil; pendingRequests = nil
    generation &+= 1
    preparation?.cancel(); preparation = nil
    preparationDeadline?.cancel(); preparationDeadline = nil
    state = captures.isEmpty ? "empty" : "ready"
  }

  func displayLayer(for windowID: WindowID) -> AVSampleBufferDisplayLayer? {
    guard let layer = displayLayers[windowID], layer.isReadyForDisplay else { return nil }
    return layer
  }

  // Keep the last compatible photo while a refresh is pending or fails. Request
  // changes still invalidate owner/dimensions, and the fixed pool remains bounded.
  func frames(windowIDs: Set<WindowID>) -> [WindowID: OverviewSurfaceFrame]? {
    guard !windowIDs.isEmpty else { return nil }
    var result: [WindowID: OverviewSurfaceFrame] = [:]
    for id in windowIDs {
      guard let capture = captures[id] else { return nil }
      result[id] = capture.frame
    }
    return result
  }

  // Opening the overview can animate a subset. Ribbon replacement still uses
  // frames(windowIDs:) so an incomplete capture never replaces native windows.
  func availableFrames(windowIDs: Set<WindowID>) -> [WindowID: OverviewSurfaceFrame]? {
    let ready = overviewReadySurfaceIDs(requested: windowIDs,
      captured: Set(captures.keys),
      displayReady: Set(windowIDs.filter { displayLayer(for: $0) != nil }))
    return frames(windowIDs: ready)
  }

  func stop(state: String = "disabled") {
    deferredPreparation?.cancel(); deferredPreparation = nil; pendingRequests = nil
    generation &+= 1
    preparation?.cancel(); preparation = nil
    preparationDeadline?.cancel(); preparationDeadline = nil
    captures = [:]; displayLayers = [:]; requested = []; failedRequests = []
    lastPreparationAt = -.infinity
    self.state = state
  }

  private enum SurfaceCaptureError: Error { case missingWindow, missingPixels, captureUnavailable }
}
