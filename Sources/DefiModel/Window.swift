import Foundation

public struct Window: Equatable, Codable, Sendable {
  public let id: WindowID
  public var appID: String
  public var title: String
  public var role: String?
  public var subrole: String?
  public var processID: Int32?
  public var monitorID: MonitorID?
  public var frame: Rect
  public var floating: Bool
  public var floatingOrigin: FloatingOrigin?
  public var forceTiling: Bool
  public var intrinsicSize: Bool

  public init(
    id: WindowID,
    appID: String,
    title: String,
    frame: Rect,
    role: String? = nil,
    subrole: String? = nil,
    processID: Int32? = nil,
    monitorID: MonitorID? = nil,
    floating: Bool = false,
    floatingOrigin: FloatingOrigin? = nil,
    forceTiling: Bool = false,
    intrinsicSize: Bool = false
  ) {
    self.id = id
    self.appID = appID
    self.title = title
    self.role = role
    self.subrole = subrole
    self.processID = processID
    self.monitorID = monitorID
    self.frame = frame
    self.floating = floating
    self.floatingOrigin = floatingOrigin
    self.forceTiling = forceTiling
    self.intrinsicSize = intrinsicSize
  }
}

public enum FloatingOrigin: String, Equatable, Codable, Sendable {
  case automatic
  case configured
  case user
}
