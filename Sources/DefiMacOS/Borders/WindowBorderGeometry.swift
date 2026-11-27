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

enum WindowBorderPlacement: Equatable, Sendable {
  /// The stroke hugs the window edge from the inside; segments overlap the
  /// first band of window content.
  case inside
  /// The stroke hugs the window edge from the outside; segments sit past the
  /// real window bounds and may be clipped by adjacent windows.
  case outside

  init(configValue: String) {
    self = configValue == "outside" ? .outside : .inside
  }
}

struct WindowBorderSegmentGeometry: Equatable, Sendable {
  let kind: WindowBorderSegmentKind
  let frame: Rect
  let pathOriginFromWindowBottom: CGPoint
}

func windowBorderSegmentGeometries(
  windowFrame: Rect,
  width: Double,
  radius: Double,
  placement: WindowBorderPlacement = .inside
) -> [WindowBorderSegmentGeometry] {
  guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
  // The outside ring renders the same inner-stroke pattern against a frame
  // expanded by the stroke width, which lands the stroke just past the real
  // window edge. Segment frames and path origins stay self-consistent.
  let outset = placement == .outside ? width : 0
  let ringFrame = Rect(
    x: windowFrame.x - outset,
    y: windowFrame.y - outset,
    width: windowFrame.width + outset * 2,
    height: windowFrame.height + outset * 2
  )
  guard ringFrame.width > 0, ringFrame.height > 0 else { return [] }
  let requestedBand = ceil(max(width * 2, radius + width, 1))
  let band = min(
    requestedBand,
    floor(min(ringFrame.width, ringFrame.height) / 2)
  )
  guard band > 0 else { return [] }

  let middleHeight = max(ringFrame.height - band * 2, 0)
  var geometries = [
    WindowBorderSegmentGeometry(
      kind: .top,
      frame: Rect(
        x: ringFrame.x,
        y: ringFrame.y,
        width: ringFrame.width,
        height: band
      ),
      pathOriginFromWindowBottom: CGPoint(
        x: 0,
        y: ringFrame.height - band
      )
    ),
    WindowBorderSegmentGeometry(
      kind: .bottom,
      frame: Rect(
        x: ringFrame.x,
        y: ringFrame.y + ringFrame.height - band,
        width: ringFrame.width,
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
          x: ringFrame.x,
          y: ringFrame.y + band,
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
          x: ringFrame.x + ringFrame.width - band,
          y: ringFrame.y + band,
          width: band,
          height: middleHeight
        ),
        pathOriginFromWindowBottom: CGPoint(
          x: ringFrame.width - band,
          y: band
        )
      )
    )
  }
  return geometries
}

