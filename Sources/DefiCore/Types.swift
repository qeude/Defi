import DefiModel

public let parkedSliverWidth = 1.0
public let minimumPixelColumnWidth = 80.0

public struct FrameAssignment: Equatable, Sendable {
  public let windowID: WindowID
  public let frame: Rect

  public init(windowID: WindowID, frame: Rect) {
    self.windowID = windowID
    self.frame = frame
  }
}

public enum LayoutError: Error, Equatable, Sendable {
  case emptyWorkspace
  case unsupportedDirection
  case focusOutOfBounds
}
