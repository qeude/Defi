import Foundation

public struct WindowID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}

public struct WorkspaceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public struct MonitorID: RawRepresentable, Hashable, Codable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }
}
