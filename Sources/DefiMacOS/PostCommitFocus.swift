import DefiModel
import DefiRuntime
import Foundation

/// What an arrangement does once its frames land: select a window, warp the cursor, and
/// report the write's outcome. One value, so every path that arranges windows carries the
/// same set instead of a subset of named arguments.
public struct PostCommitFocus: Sendable {
  public var windowID: WindowID?
  public var inputTimestamp: TimeInterval?
  public var cursorWarpWindowID: WindowID?
  public var cursorWarpInputTimestamp: TimeInterval?
  public var isCursorWarpCurrent: (@NavigationActor @Sendable () -> Bool)?
  public var completion: (@NavigationActor @Sendable (NativeFocusResult) -> Void)?
  public var requestID: (@NavigationActor @Sendable (NativeFocusRequestID?) -> Void)?

  public init(
    windowID: WindowID? = nil,
    inputTimestamp: TimeInterval? = nil,
    cursorWarpWindowID: WindowID? = nil,
    cursorWarpInputTimestamp: TimeInterval? = nil,
    isCursorWarpCurrent: (@NavigationActor @Sendable () -> Bool)? = nil,
    completion: (@NavigationActor @Sendable (NativeFocusResult) -> Void)? = nil,
    requestID: (@NavigationActor @Sendable (NativeFocusRequestID?) -> Void)? = nil
  ) {
    self.windowID = windowID
    self.inputTimestamp = inputTimestamp
    self.cursorWarpWindowID = cursorWarpWindowID
    self.cursorWarpInputTimestamp = cursorWarpInputTimestamp
    self.isCursorWarpCurrent = isCursorWarpCurrent
    self.completion = completion
    self.requestID = requestID
  }
}
