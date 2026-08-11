import Foundation

public enum Event: Equatable, Codable, Sendable {
  case windowDiscovered(Window)
  case windowDestroyed(WindowID)
  case focusChanged(WindowID)
  case commandReceived(Command)
  case configChanged
  case monitorConnected(MonitorID)
  case monitorDisconnected(MonitorID)
}
