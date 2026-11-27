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

let overviewPreviewFadeDuration: TimeInterval = 0.45

func overviewPreviewOpacity(
  startedAt: TimeInterval?,
  now: TimeInterval,
  reduceMotion: Bool,
  duration: TimeInterval = overviewPreviewFadeDuration
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
