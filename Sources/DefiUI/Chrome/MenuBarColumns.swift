import AppKit
import DefiMacOS

/// The columns item: one bar per column of the focused display's active workspace, in image points.
struct MenuBarColumnsLayout: Equatable {
  struct Bar: Equatable {
    var windowID: UInt64
    var rect: CGRect
    var windows: Int
    var alpha: CGFloat
  }

  var size: CGSize
  var bars: [Bar]
  /// The screen, over the columns it shows.
  var frame: CGRect

  func windowID(atX x: CGFloat) -> UInt64? {
    bars.first { $0.rect.minX <= x && x <= $0.rect.maxX }?.windowID
      ?? bars.min { abs($0.rect.midX - x) < abs($1.rect.midX - x) }
        .flatMap { abs($0.rect.midX - x) <= $0.rect.width / 2 + menuBarColumnGap ? $0.windowID : nil }
  }
}

private let menuBarColumnGap: CGFloat = 2
private let menuBarColumnPadding: CGFloat = 3
private let menuBarColumnMinimum: CGFloat = 2
/// Points one screen width of columns takes while the item has room.
private let menuBarColumnsPerScreen: CGFloat = 18

func menuBarColumnsLayout(_ monitor: MenuMonitor?, maxWidth: CGFloat) -> MenuBarColumnsLayout {
  let height: CGFloat = 18
  guard let monitor, !monitor.columns.isEmpty, monitor.stripWidth > 0 else {
    return MenuBarColumnsLayout(size: CGSize(width: 12, height: height), bars: [],
      frame: CGRect(x: 1, y: 0.75, width: 10, height: 16.5))
  }
  let columns = monitor.columns
  let total = columns.reduce(0) { $0 + $1.width }
  let room = maxWidth - 2 * menuBarColumnPadding - menuBarColumnGap * CGFloat(columns.count - 1)
  let scale = min(menuBarColumnsPerScreen / monitor.stripWidth, max(room, 0) / max(total, 1))
  var x = menuBarColumnPadding
  var bars: [MenuBarColumnsLayout.Bar] = []
  for (index, column) in columns.enumerated() {
    let rect = CGRect(x: x, y: 3, width: max(menuBarColumnMinimum, column.width * scale), height: 12)
    let center = column.x + column.width / 2
    let onScreen = center > 0 && center < monitor.stripWidth
    var alpha: CGFloat = onScreen ? 0.55 : 0.28
    if index == monitor.focusedColumn { alpha = 1 }
    bars.append(.init(windowID: column.windowID, rect: rect, windows: column.windows, alpha: alpha))
    x = rect.maxX + menuBarColumnGap
  }
  let width = (x - menuBarColumnGap + menuBarColumnPadding - 0.001).rounded(.up)
  // Bars have gaps and minimum widths, so map each screen edge through the column it falls in.
  // An edge on a column boundary belongs to the column on screen: the next one for the left edge.
  func imageX(_ point: Double, leading: Bool) -> CGFloat {
    var previous: (end: Double, maxX: CGFloat)?
    for (column, bar) in zip(columns, bars) {
      if point < column.x {
        guard let previous, column.x > previous.end else { return bar.rect.minX - CGFloat(column.x - point) * scale }
        let t = CGFloat((point - previous.end) / (column.x - previous.end))
        return previous.maxX + max(0, t) * (bar.rect.minX - previous.maxX)
      }
      if leading ? point < column.x + column.width : point <= column.x + column.width {
        return bar.rect.minX + CGFloat((point - column.x) / max(column.width, 1)) * bar.rect.width
      }
      previous = (column.x + column.width, bar.rect.maxX)
    }
    return bars[bars.count - 1].rect.maxX + CGFloat(point - (previous?.end ?? 0)) * scale
  }
  let minX = max(0.75, imageX(0, leading: true) - 1.5)
  let maxX = min(width - 0.75, imageX(monitor.stripWidth, leading: false) + 1.5)
  return MenuBarColumnsLayout(
    size: CGSize(width: width, height: height), bars: bars,
    frame: CGRect(x: minX, y: 0.75, width: max(maxX - minX, 3), height: 16.5))
}

func interpolate(_ from: MenuBarColumnsLayout, _ to: MenuBarColumnsLayout, _ t: CGFloat) -> MenuBarColumnsLayout {
  if t <= 0 { return from }
  if t >= 1 { return to }
  func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
  func mix(_ a: CGRect, _ b: CGRect) -> CGRect {
    CGRect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
  }
  let sources = Dictionary(from.bars.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
  let bars = to.bars.map { target -> MenuBarColumnsLayout.Bar in
    // A new column fades in where it lands.
    guard let source = sources[target.windowID] else { return .init(windowID: target.windowID, rect: target.rect,
      windows: target.windows, alpha: target.alpha * t) }
    return .init(windowID: target.windowID, rect: mix(source.rect, target.rect),
      windows: t < 0.5 ? source.windows : target.windows, alpha: mix(source.alpha, target.alpha))
  }
  return MenuBarColumnsLayout(size: CGSize(width: mix(from.size.width, to.size.width), height: to.size.height),
    bars: bars, frame: mix(from.frame, to.frame))
}

func menuBarColumnsImage(_ layout: MenuBarColumnsLayout) -> NSImage {
  let image = NSImage(size: layout.size, flipped: true) { _ in
    for bar in layout.bars {
      NSColor.black.withAlphaComponent(bar.alpha).setFill()
      // Past three stacked windows the slices would be thinner than a point.
      let count = min(bar.windows, 3)
      let slice = (bar.rect.height - CGFloat(count - 1)) / CGFloat(count)
      for index in 0..<count {
        let rect = CGRect(x: bar.rect.minX, y: bar.rect.minY + CGFloat(index) * (slice + 1),
          width: bar.rect.width, height: slice)
        NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
      }
    }
    NSColor.black.withAlphaComponent(0.9).setStroke()
    let path = NSBezierPath(roundedRect: layout.frame, xRadius: 3, yRadius: 3)
    path.lineWidth = 1.2
    path.stroke()
    return true
  }
  image.isTemplate = true
  return image
}
