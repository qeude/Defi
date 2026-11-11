import CoreGraphics
import DefiModel
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum WindowPreviewError: Error, Equatable {
  case notAuthorized
  case noPicture
}

/// The latest picture Defi holds of a window, as a JPEG data URI for `defi window-preview`.
/// It reads the capture store only: nothing is captured for it and nothing reaches the disk.
public func windowPreviewDataURI(_ id: WindowID, maxSide: Int = 800) -> Result<String, WindowPreviewError> {
  guard RibbonProxyStore.shared.isAuthorized else { return .failure(.notAuthorized) }
  guard let picture = WindowCaptureStore.shared.picture(id),
    let image = picture.image ?? picture.buffer.flatMap(ribbonProxyTaggedImage),
    let jpeg = windowPreviewJPEG(image, background: picture.edge, maxSide: maxSide)
  else { return .failure(.noPicture) }
  return .success("data:image/jpeg;base64,\(jpeg.base64EncodedString())")
}

/// Scaled down to `maxSide` pixels, never up. JPEG has no alpha, so the window's rounded corners
/// take its edge colour instead of black.
func windowPreviewJPEG(_ image: CGImage, background: CGColor?, maxSide: Int) -> Data? {
  let scale = min(1, Double(maxSide) / Double(max(image.width, image.height, 1)))
  let width = max(1, Int((Double(image.width) * scale).rounded()))
  let height = max(1, Int((Double(image.height) * scale).rounded()))
  guard let space = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { return nil }
  let bounds = CGRect(x: 0, y: 0, width: width, height: height)
  context.setFillColor(background ?? CGColor(gray: 1, alpha: 1))
  context.fill(bounds)
  context.interpolationQuality = .high
  context.draw(image, in: bounds)
  let data = NSMutableData()
  guard let scaled = context.makeImage(),
    let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
  else { return nil }
  CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
  return CGImageDestinationFinalize(destination) ? data as Data : nil
}
