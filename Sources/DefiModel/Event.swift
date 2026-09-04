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

public enum NativeFocusResult: Equatable, Sendable {
  case completed
  case completedWithoutMutation
  case frameSuperseded
  case superseded
  case supersededAfterMutation
  case cancelled
  case cancelledAfterMutation
  case cancelledAfterInputMutation
  case failed
  case failedAfterMutation
}
