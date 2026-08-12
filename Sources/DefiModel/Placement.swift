import Foundation

public enum OffWorkspaceStrategy: String, Codable, Sendable {
  case parkOffscreen = "park_offscreen"
}

public enum NewWindowPlacement: String, Codable, Sendable {
  case afterActiveColumn = "after-active-column"
}
