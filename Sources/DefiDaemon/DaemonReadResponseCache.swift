import DefiIPC
import Foundation

/// Thread-safe short-TTL cache for read-only IPC responses.
///
/// Read commands ("status", "trace", "list-workspaces") are served from this
/// cache without synchronizing on the main thread, so CLI latency stays low
/// while the daemon is busy with accessibility writes. The TTL bounds
/// staleness; mutating commands never touch the cache.
final class DaemonReadResponseCache: @unchecked Sendable {
  static let readCommandKeys: Set<String> = [
    "status",
    "trace",
    "list-workspaces",
    "list-workspaces --json",
  ]

  private let lock = NSLock()
  private var responses: [String: (message: String, builtAt: TimeInterval)] = [:]
  private let maxAge: TimeInterval

  init(maxAge: TimeInterval = 0.25) {
    self.maxAge = maxAge
  }

  static func isReadCommand(_ rawCommand: String) -> Bool {
    readCommandKeys.contains(rawCommand)
  }

  func response(for key: String, now: TimeInterval) -> CommandResponse? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = responses[key], now - entry.builtAt <= maxAge else {
      return nil
    }
    return .success(entry.message)
  }

  func store(message: String, for key: String, now: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    responses[key] = (message, now)
  }
}
