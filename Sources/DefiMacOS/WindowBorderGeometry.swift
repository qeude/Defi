import AppKit
import DefiCore
import DefiModel
import QuartzCore

enum WindowBorderSegmentKind: CaseIterable, Sendable {
  case top
  case bottom
  case left
  case right
}

struct WindowBorderSegmentGeometry: Equatable, Sendable {
  let kind: WindowBorderSegmentKind
  let frame: Rect
  let pathOriginFromWindowBottom: CGPoint
}

func windowBorderSegmentGeometries(
  windowFrame: Rect,
  width: Double,
  radius: Double
) -> [WindowBorderSegmentGeometry] {
  guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
  let requestedBand = ceil(max(width * 2, radius + width, 1))
  let band = min(
    requestedBand,
    floor(min(windowFrame.width, windowFrame.height) / 2)
  )
  guard band > 0 else { return [] }

  let middleHeight = max(windowFrame.height - band * 2, 0)
  var geometries = [
    WindowBorderSegmentGeometry(
      kind: .top,
      frame: Rect(
        x: windowFrame.x,
        y: windowFrame.y,
        width: windowFrame.width,
        height: band
      ),
      pathOriginFromWindowBottom: CGPoint(
        x: 0,
        y: windowFrame.height - band
      )
    ),
    WindowBorderSegmentGeometry(
      kind: .bottom,
      frame: Rect(
        x: windowFrame.x,
        y: windowFrame.y + windowFrame.height - band,
        width: windowFrame.width,
        height: band
      ),
      pathOriginFromWindowBottom: .zero
    ),
  ]
  if middleHeight > 0 {
    geometries.append(
      WindowBorderSegmentGeometry(
        kind: .left,
        frame: Rect(
          x: windowFrame.x,
          y: windowFrame.y + band,
          width: band,
          height: middleHeight
        ),
        pathOriginFromWindowBottom: CGPoint(x: 0, y: band)
      )
    )
    geometries.append(
      WindowBorderSegmentGeometry(
        kind: .right,
        frame: Rect(
          x: windowFrame.x + windowFrame.width - band,
          y: windowFrame.y + band,
          width: band,
          height: middleHeight
        ),
        pathOriginFromWindowBottom: CGPoint(
          x: windowFrame.width - band,
          y: band
        )
      )
    )
  }
  return geometries
}

