import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import DefiMacOS

struct WindowPreviewTests {
  @Test
  func `A window picture becomes a JPEG at most 800 pixels long, its clear corners filled`() throws {
    // A 1600×1000 window whose top-left corner is transparent, like a rounded window corner.
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
      CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
    context.clear(CGRect(x: 0, y: 900, width: 100, height: 100))
    let window = try #require(context.makeImage())

    let jpeg = try #require(windowPreviewJPEG(window, background: CGColor(gray: 1, alpha: 1), maxSide: 800))
    let decoded = try #require(
      CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(decoded.width == 800)
    #expect(decoded.height == 500)
    #expect(pixel(decoded, x: 2, y: 2).red > 230, "The clear corner takes the edge colour, not black")
    #expect(pixel(decoded, x: 400, y: 250).blue > 230)

    let small = try #require(windowPreviewJPEG(window, background: nil, maxSide: 4000))
    let unscaled = try #require(
      CGImageSourceCreateWithData(small as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(unscaled.width == 1600, "Pictures are never scaled up")
  }

  private func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, blue: Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Int(bytes[0]), Int(bytes[2]))
  }
}
