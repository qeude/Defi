import Darwin
import DefiModel
import Foundation

/// One managed window as `list-windows --json` and the event stream report it.
/// Titles leave the daemon only over the local socket, never into diagnostics.
public struct WindowSnapshot: Codable, Equatable, Sendable {
  public struct WorkspaceReference: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let position: Int
  }

  public let id: UInt64
  public let appID: String
  public let appName: String?
  public let title: String
  public let workspace: WorkspaceReference
  public let monitorID: UInt64
  public let display: Int
  /// 1-based column and row in the strip; nil for floating windows.
  public let column: Int?
  public let row: Int?
  public let floating: Bool
  public let focused: Bool

  func hasSameLocation(as other: WindowSnapshot) -> Bool {
    workspace == other.workspace && monitorID == other.monitorID && display == other.display
      && column == other.column && row == other.row && floating == other.floating
  }
}

public struct WindowListSnapshot: Codable, Equatable, Sendable {
  public let version: Int
  public let windows: [WindowSnapshot]

  public init(version: Int = 1, windows: [WindowSnapshot]) {
    self.version = version
    self.windows = windows
  }
}

/// Lists managed windows in display, workspace, column, row order, then floating windows.
public func makeWindowListSnapshot(
  monitors: [Monitor],
  windows: [WindowID: Window],
  displayOrder: [MonitorID],
  focusedMonitorID: MonitorID?,
  appName: (Window) -> String? = { _ in nil }
) -> WindowListSnapshot {
  var result: [WindowSnapshot] = []
  for (display, monitor) in orderedMonitors(monitors, displayOrder: displayOrder) {
    for (offset, workspace) in monitor.workspaces.enumerated() {
      let reference = WindowSnapshot.WorkspaceReference(
        id: workspace.id.rawValue, name: workspace.name, position: offset + 1
      )
      let focusedWindowID =
        monitor.id == focusedMonitorID && workspace.id == monitor.activeWorkspace
        ? selectedWindowID(in: workspace) : nil
      func append(_ windowID: WindowID, column: Int?, row: Int?) {
        guard let window = windows[windowID] else { return }
        result.append(WindowSnapshot(
          id: windowID.rawValue, appID: window.appID, appName: appName(window),
          title: window.title, workspace: reference,
          monitorID: monitor.id.rawValue, display: display,
          column: column, row: row, floating: column == nil,
          focused: windowID == focusedWindowID
        ))
      }
      for (columnOffset, column) in workspace.columns.enumerated() {
        for (rowOffset, windowID) in column.windows.enumerated() {
          append(windowID, column: columnOffset + 1, row: rowOffset + 1)
        }
      }
      for windowID in workspace.floatingWindows {
        append(windowID, column: nil, row: nil)
      }
    }
  }
  return WindowListSnapshot(windows: result)
}

/// Everything the event stream reports, captured at one instant.
public struct EventStreamState: Equatable, Sendable {
  public let workspaces: WorkspaceStateSnapshot
  public let windows: [WindowSnapshot]

  public init(workspaces: WorkspaceStateSnapshot, windows: [WindowSnapshot]) {
    self.workspaces = workspaces
    self.windows = windows
  }

  var focusedWindow: WindowSnapshot? { windows.first(where: \.focused) }
}

/// One line of `defi subscribe --json`. Fields absent for an event are omitted.
public struct StreamEvent: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let event: String
  public var workspaces: WorkspaceStateSnapshot?
  public var windows: [WindowSnapshot]?
  public var window: WindowSnapshot?
  public var windowID: UInt64?
  public var monitorID: UInt64?
  public var display: Int?
  public var workspace: WindowSnapshot.WorkspaceReference?

  init(_ event: String) {
    version = Self.currentVersion
    self.event = event
  }

  public static func snapshot(_ state: EventStreamState) -> StreamEvent {
    var event = StreamEvent("snapshot")
    event.workspaces = state.workspaces
    event.windows = state.windows
    return event
  }
}

/// The events that turn `old` into `new`, coarse state first, focus last.
public func streamEvents(from old: EventStreamState, to new: EventStreamState) -> [StreamEvent] {
  var events: [StreamEvent] = []
  let oldDisplays = old.workspaces.monitors.map { [$0.id, UInt64($0.display)] }
  if oldDisplays != new.workspaces.monitors.map({ [$0.id, UInt64($0.display)] }) {
    var event = StreamEvent("monitors-changed")
    event.workspaces = new.workspaces
    events.append(event)
  }
  if old.workspaces != new.workspaces {
    var event = StreamEvent("workspaces-changed")
    event.workspaces = new.workspaces
    events.append(event)
  }
  let oldActive = Dictionary(
    old.workspaces.monitors.map { ($0.id, $0.activeWorkspace) }, uniquingKeysWith: { $1 }
  )
  for monitor in new.workspaces.monitors where oldActive[monitor.id] != monitor.activeWorkspace {
    guard let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace })
    else { continue }
    var event = StreamEvent("workspace-activated")
    event.monitorID = monitor.id
    event.display = monitor.display
    event.workspace = .init(id: workspace.id, name: workspace.name, position: workspace.position)
    events.append(event)
  }
  let oldWindows = Dictionary(old.windows.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
  let newIDs = Set(new.windows.map(\.id))
  for window in old.windows where !newIDs.contains(window.id) {
    var event = StreamEvent("window-closed")
    event.windowID = window.id
    events.append(event)
  }
  for window in new.windows {
    let name: String
    if let previous = oldWindows[window.id] {
      if !previous.hasSameLocation(as: window) {
        name = "window-moved"
      } else if previous.title != window.title || previous.appName != window.appName {
        name = "window-changed"
      } else {
        continue
      }
    } else {
      name = "window-opened"
    }
    var event = StreamEvent(name)
    event.window = window
    events.append(event)
  }
  let focused = new.focusedWindow
  if old.focusedWindow?.id != focused?.id
    || old.workspaces.focusedMonitorID != new.workspaces.focusedMonitorID
  {
    var event = StreamEvent("focus-changed")
    event.window = focused
    event.windowID = focused?.id
    event.monitorID = new.workspaces.focusedMonitorID
    events.append(event)
  }
  return events
}

/// Fans state out to `defi subscribe` clients without ever blocking the publisher.
///
/// `publish` only stores the latest state; a flush on the hub's own queue diffs it
/// against what clients last received, so bursts of changes coalesce into one batch.
/// Each client has a bounded output buffer on a non-blocking socket; a client that
/// lets it overflow is disconnected rather than slowing anyone down.
public final class EventStreamHub: @unchecked Sendable {
  private final class Client {
    let descriptor: Int32
    var pending = Data()
    var needsSnapshot = false
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?

    init(descriptor: Int32) { self.descriptor = descriptor }
  }

  private let queue = DispatchQueue(label: "com.qeude.defi.ipc.events", qos: .utility)
  private let coalescingInterval: DispatchTimeInterval
  private let maximumPendingBytes: Int
  private let maximumClients: Int
  private var latest: EventStreamState?
  private var sent: EventStreamState?
  private var flushScheduled = false
  private var clients: [Int32: Client] = [:]

  public init(
    coalescingInterval: DispatchTimeInterval = .milliseconds(30),
    maximumPendingBytes: Int = 1 << 20,
    maximumClients: Int = 32
  ) {
    self.coalescingInterval = coalescingInterval
    self.maximumPendingBytes = maximumPendingBytes
    self.maximumClients = maximumClients
  }

  public var clientCount: Int { queue.sync { clients.count } }

  public func publish(_ state: EventStreamState) {
    queue.async { [self] in
      latest = state
      guard !flushScheduled else { return }
      flushScheduled = true
      queue.asyncAfter(deadline: .now() + coalescingInterval) { [self] in
        flushScheduled = false
        flush()
      }
    }
  }

  /// Takes ownership of a connected socket; its first line is a snapshot.
  public func subscribe(_ descriptor: Int32) {
    queue.async { [self] in
      guard clients.count < maximumClients else {
        if var line = try? encodedResponseForIPC(.failure("too many subscribers")) {
          line.append(0x0A)
          try? writeAll(line, to: descriptor)
        }
        Darwin.close(descriptor)
        return
      }
      guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else {
        Darwin.close(descriptor)
        return
      }
      // Deliver pending changes to existing clients before this one joins, so its
      // snapshot comes first and every later diff starts from that state.
      flush()
      let client = Client(descriptor: descriptor)
      clients[descriptor] = client
      let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
      readSource.setEventHandler { [weak self, weak client] in
        guard let client else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
          self?.disconnect(client)
        }
      }
      readSource.setCancelHandler { Darwin.close(descriptor) }
      client.readSource = readSource
      readSource.resume()
      if let sent {
        enqueue(encodedLines([.snapshot(sent)]), to: client)
      } else {
        client.needsSnapshot = true
      }
    }
  }

  private func flush() {
    guard let latest else { return }
    let events = sent.map { latest == $0 ? [] : streamEvents(from: $0, to: latest) } ?? []
    sent = latest
    let snapshot = encodedLines([.snapshot(latest)])
    let lines = encodedLines(events)
    for client in Array(clients.values) {
      if client.needsSnapshot {
        client.needsSnapshot = false
        enqueue(snapshot, to: client)
      } else if !events.isEmpty {
        enqueue(lines, to: client)
      }
    }
  }

  private func encodedLines(_ events: [StreamEvent]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = Data()
    for event in events {
      guard let line = try? encoder.encode(event) else { continue }
      data.append(line)
      data.append(0x0A)
    }
    return data
  }

  private func enqueue(_ lines: Data, to client: Client) {
    client.pending.append(lines)
    guard client.pending.count <= maximumPendingBytes else {
      disconnect(client)
      return
    }
    drain(client)
  }

  private func drain(_ client: Client) {
    while !client.pending.isEmpty {
      let count = client.pending.withUnsafeBytes {
        Darwin.write(client.descriptor, $0.baseAddress, $0.count)
      }
      if count > 0 {
        client.pending.removeFirst(count)
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN {
        guard client.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(
          fileDescriptor: client.descriptor, queue: queue
        )
        source.setEventHandler { [weak self, weak client] in
          if let client { self?.drain(client) }
        }
        client.writeSource = source
        source.resume()
        return
      } else {
        disconnect(client)
        return
      }
    }
    client.writeSource?.cancel()
    client.writeSource = nil
  }

  private func disconnect(_ client: Client) {
    guard clients.removeValue(forKey: client.descriptor) != nil else { return }
    // The read source closes the descriptor, so it is cancelled after the write source.
    if let writeSource = client.writeSource, let readSource = client.readSource {
      writeSource.setCancelHandler { readSource.cancel() }
      writeSource.cancel()
    } else {
      client.readSource?.cancel()
    }
    client.writeSource = nil
  }
}
