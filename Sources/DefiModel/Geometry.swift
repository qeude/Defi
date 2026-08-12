import Foundation

public struct Rect: Hashable, Codable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public enum ColumnWidth: Equatable, Codable, Sendable {
  case fraction(Double)
  case pixels(Double)
}
