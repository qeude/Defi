import AppKit
import DefiModel

// Rasterize small, unchanged labels once; moving a card must not invoke the
// typesetter or resolve application icon representations on every refresh.
@MainActor
func overviewLabelBitmap(size: CGSize, scale: CGFloat, draw: () -> Void) -> NSImage? {
  guard size.width.isFinite, size.height.isFinite, scale.isFinite,
    size.width > 0, size.height > 0, scale > 0 else { return nil }
  let width = Int(ceil(size.width * scale))
  let height = Int(ceil(size.height * scale))
  guard width <= 16_384, height <= 256,
    let context = CGContext(data: nil, width: width, height: height,
      bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  context.translateBy(x: 0, y: CGFloat(height))
  context.scaleBy(x: scale, y: -scale)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  guard let image = context.makeImage() else { return nil }
  return NSImage(cgImage: image, size: size)
}

@MainActor
final class OverviewTitleCache {
  struct Label {
    let image: NSImage
    let intrinsicSize: CGSize
  }
  private struct Entry {
    let text: String
    let fontSize: CGFloat
    let maximumWidth: CGFloat
    let scale: CGFloat
    let label: Label
    let bytes: Int
  }
  private var entries: [WindowID: Entry] = [:]
  private let maximumBytes: Int
  private(set) var byteCount = 0
  private(set) var rasterizationCount = 0

  init(maximumBytes: Int = 4 * 1024 * 1024) { self.maximumBytes = maximumBytes }

  func prune(windowIDs: Set<WindowID>) {
    for id in Array(entries.keys) where !windowIDs.contains(id) {
      byteCount -= entries.removeValue(forKey: id)?.bytes ?? 0
    }
  }

  func label(for id: WindowID, text: String, fontSize: CGFloat,
    maximumWidth: CGFloat, scale: CGFloat) -> Label? {
    if let entry = entries[id], entry.text == text, entry.fontSize == fontSize,
      entry.maximumWidth == maximumWidth, entry.scale == scale { return entry.label }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
      .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]
    let title = text as NSString
    let intrinsic = title.size(withAttributes: attributes)
    let size = CGSize(width: min(intrinsic.width, maximumWidth), height: intrinsic.height)
    guard let image = overviewLabelBitmap(size: size, scale: scale, draw: {
      title.draw(in: CGRect(origin: .zero, size: size), withAttributes: attributes)
    }) else { return nil }
    rasterizationCount += 1
    let label = Label(image: image, intrinsicSize: intrinsic)
    let bytes = Int(ceil(size.width * scale)) * Int(ceil(size.height * scale)) * 4
    byteCount -= entries.removeValue(forKey: id)?.bytes ?? 0
    guard bytes <= maximumBytes else { return label }
    if byteCount + bytes > maximumBytes { entries.removeAll(); byteCount = 0 }
    entries[id] = Entry(text: text, fontSize: fontSize, maximumWidth: maximumWidth,
      scale: scale, label: label, bytes: bytes)
    byteCount += bytes
    return label
  }
}
