import DefiModel

public struct ReservedEdges: Codable, Equatable, Sendable {
  public var top: Double
  public var bottom: Double

  public init(top: Double = 0, bottom: Double = 0) {
    self.top = top
    self.bottom = bottom
  }
}

public func viewportByApplyingReservedEdges(
  _ viewport: Rect,
  edges: ReservedEdges
) -> Rect {
  let top = min(max(edges.top, 0), viewport.height)
  let remainingHeight = max(viewport.height - top, 0)
  let bottom = min(max(edges.bottom, 0), remainingHeight)
  return Rect(
    x: viewport.x,
    y: viewport.y + top,
    width: viewport.width,
    height: remainingHeight - bottom
  )
}
