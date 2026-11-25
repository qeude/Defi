import AppKit

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
  /// Encloses the columns on screen.
  var frame: CGRect

  func windowID(atX x: CGFloat) -> UInt64? {
    bars.min { abs($0.rect.midX - x) < abs($1.rect.midX - x) }
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
  var visible: [CGRect] = []
  for (index, column) in columns.enumerated() {
    let rect = CGRect(x: x, y: 3, width: max(menuBarColumnMinimum, column.width * scale), height: 12)
    let center = column.x + column.width / 2
    let onScreen = center > 0 && center < monitor.stripWidth
    if onScreen { visible.append(rect) }
    var alpha: CGFloat = onScreen ? 0.55 : 0.28
    if index == monitor.focusedColumn { alpha = 1 }
    bars.append(.init(windowID: column.windowID, rect: rect, windows: column.windows, alpha: alpha))
    x = rect.maxX + menuBarColumnGap
  }
  let first = visible.first
    ?? monitor.focusedColumn.flatMap { bars.indices.contains($0) ? bars[$0].rect : nil } ?? bars[0].rect
  let last = visible.last ?? first
  return MenuBarColumnsLayout(
    size: CGSize(width: (x - menuBarColumnGap + menuBarColumnPadding - 0.001).rounded(.up), height: height), bars: bars,
    frame: CGRect(x: first.minX - 1.5, y: 0.75, width: last.maxX - first.minX + 3, height: 16.5))
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
