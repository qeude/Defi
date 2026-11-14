import Darwin
import DefiModel
import Foundation

public struct CommandRequest: Codable, Equatable, Sendable {
  public let command: String
  public let monitorIndex: Int?

  public init(command: String, monitorIndex: Int? = nil) {
    self.command = command
    self.monitorIndex = monitorIndex
  }
}

public struct WorkspaceStateSnapshot: Codable, Equatable, Sendable {
  public let version: Int
  public let focusedMonitorID: UInt64?
  public let monitors: [MonitorWorkspaceSnapshot]

  public init(
    version: Int = 2,
    focusedMonitorID: UInt64?,
    monitors: [MonitorWorkspaceSnapshot]
  ) {
    self.version = version
    self.focusedMonitorID = focusedMonitorID
    self.monitors = monitors
  }
}

public struct MonitorWorkspaceSnapshot: Codable, Equatable, Sendable {
  public let id: UInt64
  public let display: Int
  public let focused: Bool
  public let activeWorkspace: String
  public let workspaces: [WorkspaceSnapshot]

  public init(
    id: UInt64,
    display: Int,
    focused: Bool,
    activeWorkspace: String,
    workspaces: [WorkspaceSnapshot]
  ) {
    self.id = id
    self.display = display
    self.focused = focused
    self.activeWorkspace = activeWorkspace
    self.workspaces = workspaces
  }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public let id: String
  public let position: Int
  public let name: String?
  public let icon: String?
  public let kind: WorkspaceKind
  public let active: Bool
  public let windowCount: Int
  public let occupied: Bool
  public let applications: [String]
  public let focusedApplication: String?
  /// The selected window on an active workspace, if any.
  public let selectedWindowID: UInt64?
  public let windows: [WorkspaceWindowSnapshot]

  public init(
    id: String,
    position: Int,
    name: String?,
    kind: WorkspaceKind,
    active: Bool,
    windowCount: Int,
    applications: [String],
    focusedApplication: String?,
    icon: String? = nil,
    selectedWindowID: UInt64? = nil,
    windows: [WorkspaceWindowSnapshot] = []
  ) {
    self.id = id
    self.position = position
    self.name = name
    self.icon = icon
    self.kind = kind
    self.active = active
    self.windowCount = windowCount
    self.occupied = windowCount > 0
    self.applications = applications
    self.focusedApplication = focusedApplication
    self.selectedWindowID = selectedWindowID
    self.windows = windows
  }
}

public struct WorkspaceWindowSnapshot: Codable, Equatable, Sendable {
  public let id: UInt64
  public let appID: String
  /// 1-based column and row in the strip; nil for floating windows.
  public let column: Int?
  public let row: Int?
  public let floating: Bool
  public let selected: Bool
}

public func makeWorkspaceStateSnapshot(
  monitors: [Monitor],
  windows: [WindowID: Window],
  displayOrder: [MonitorID],
  focusedMonitorID: MonitorID?,
  workspaceIcons: [String: String] = [:]
) -> WorkspaceStateSnapshot {
  WorkspaceStateSnapshot(
    focusedMonitorID: focusedMonitorID?.rawValue,
    monitors: orderedMonitors(monitors, displayOrder: displayOrder).map { display, monitor in
      MonitorWorkspaceSnapshot(
        id: monitor.id.rawValue,
        display: display,
        focused: monitor.id == focusedMonitorID,
        activeWorkspace: monitor.activeWorkspace.rawValue,
        workspaces: monitor.workspaces.enumerated().map { offset, workspace in
          let active = workspace.id == monitor.activeWorkspace
          let selectedWindow =
            active ? selectedWindowID(in: workspace).flatMap { windows[$0] } : nil
          var workspaceWindows: [WorkspaceWindowSnapshot] = []
          forEachWorkspaceWindow(in: workspace) { windowID, column, row in
            guard let window = windows[windowID] else { return }
            workspaceWindows.append(WorkspaceWindowSnapshot(
              id: windowID.rawValue, appID: window.appID, column: column, row: row,
              floating: column == nil, selected: windowID == selectedWindow?.id
            ))
          }
          return WorkspaceSnapshot(
            id: workspace.id.rawValue,
            position: offset + 1,
            name: workspace.name,
            kind: workspace.kind,
            active: active,
            windowCount: workspaceWindows.count,
            applications: Array(Set(workspaceWindows.map(\.appID))).sorted(),
            focusedApplication: selectedWindow?.appID,
            icon: workspace.name.flatMap { workspaceIcons[$0] },
            selectedWindowID: selectedWindow?.id.rawValue,
            windows: workspaceWindows
          )
        }
      )
    }
  )
}

/// Monitors in AppKit display order, each with its 1-based display index.
func orderedMonitors(
  _ monitors: [Monitor],
  displayOrder: [MonitorID]
) -> [(display: Int, monitor: Monitor)] {
  let monitorByID = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
  let orderedIDs =
    displayOrder.filter { monitorByID[$0] != nil }
    + monitors.map(\.id).filter { displayOrder.contains($0) == false }
  return orderedIDs.enumerated().compactMap { offset, monitorID in
    monitorByID[monitorID].map { (offset + 1, $0) }
  }
}

func selectedWindowID(in workspace: Workspace) -> WindowID? {
  if workspace.focusedLayer == .floating,
    workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
  {
    return workspace.floatingWindows[workspace.focusedFloatingWindow]
  }
  guard workspace.columns.indices.contains(workspace.focusedColumn) else { return nil }
  let column = workspace.columns[workspace.focusedColumn]
  guard column.windows.indices.contains(column.focusedWindow) else { return nil }
  return column.windows[column.focusedWindow]
}

func forEachWorkspaceWindow(
  in workspace: Workspace,
  _ visit: (WindowID, Int?, Int?) -> Void
) {
  for (columnOffset, column) in workspace.columns.enumerated() {
    for (rowOffset, windowID) in column.windows.enumerated() {
      visit(windowID, columnOffset + 1, rowOffset + 1)
    }
  }
  for windowID in workspace.floatingWindows {
    visit(windowID, nil, nil)
  }
}

public struct CommandResponse: Codable, Equatable, Sendable {
  public let ok: Bool
  public let message: String

  public init(ok: Bool, message: String) {
    self.ok = ok
    self.message = message
  }

  public static func success(_ message: String = "ok") -> CommandResponse {
    CommandResponse(ok: true, message: message)
  }

  public static func failure(_ message: String) -> CommandResponse {
    CommandResponse(ok: false, message: message)
  }
}

private let maximumIPCRequestBytes = 65_536
/// Large enough for `list-windows --json` with hundreds of long titles.
let maximumIPCResponseBytes = 4 << 20

/// The request that turns a connection into an event stream.
public let subscribeCommand = "subscribe"

func encodedResponseForIPC(_ response: CommandResponse) throws -> Data {
  let encoder = JSONEncoder()
  let encoded = try encoder.encode(response)
  guard encoded.count > maximumIPCResponseBytes else { return encoded }
  return try encoder.encode(CommandResponse.failure("IPC response too large"))
}

public enum IPCError: Error, CustomStringConvertible, Sendable {
  case invalidSocketPath
  case systemCall(String, Int32)
  case invalidResponse
  case requestTooLarge
  case readTimeout
  case rejected(String)

  public var description: String {
    switch self {
    case .invalidSocketPath:
      "invalid Unix socket path"
    case .systemCall(let name, let code):
      "\(name) failed: \(String(cString: strerror(code)))"
    case .invalidResponse:
      "invalid daemon response"
    case .requestTooLarge:
      "IPC request too large"
    case .readTimeout:
      "IPC request read timed out"
    case .rejected(let message):
      message
    }
  }
}

public enum SocketPath {
  public static var defaultURL: URL {
    URL(filePath: NSTemporaryDirectory())
      .appending(path: "defi-\(getuid()).sock")
  }
}

public enum DaemonLockPath {
  public static var defaultURL: URL {
    URL(filePath: NSTemporaryDirectory())
      .appending(path: "defi-\(getuid()).lock")
  }
}

public final class UnixSocketServer: @unchecked Sendable {
  public let url: URL
  private let descriptor: Int32

  public var listeningFileDescriptor: Int32 { descriptor }

  public init(url: URL = SocketPath.defaultURL) throws {
    self.url = url
    descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw IPCError.systemCall("socket", errno)
    }

    do {
      try configureNoSigPipe(descriptor)
      unlink(url.path)
      try withSocketAddress(path: url.path) { address, length in
        guard bind(descriptor, address, length) == 0 else {
          throw IPCError.systemCall("bind", errno)
        }
      }
      guard listen(descriptor, 16) == 0 else {
        throw IPCError.systemCall("listen", errno)
      }
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw IPCError.systemCall("fcntl", errno)
      }
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  deinit {
    Darwin.close(descriptor)
    removeSocketFile()
  }

  public func removeSocketFile() {
    unlink(url.path)
  }

  @discardableResult
  public func poll(
    on clientQueue: DispatchQueue? = nil,
    handler: @escaping @Sendable (CommandRequest) -> CommandResponse,
    completion: (@Sendable (CommandRequest) -> Void)? = nil,
    subscriber: (@Sendable (Int32) -> Void)? = nil
  ) throws -> Bool {
    let client = accept(descriptor, nil, nil)
    if client < 0 {
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return false
      }
      throw IPCError.systemCall("accept", errno)
    }
    do {
      try configureNoSigPipe(client)
      try configureBlocking(client)
      try configureReadTimeout(client)
    } catch {
      Darwin.close(client)
      throw error
    }
    if let clientQueue {
      clientQueue.async {
        try? self.serve(client, handler: handler, completion: completion, subscriber: subscriber)
      }
    } else {
      try serve(client, handler: handler, completion: completion, subscriber: subscriber)
    }
    return true
  }

  private func serve(
    _ client: Int32,
    handler: @Sendable (CommandRequest) -> CommandResponse,
    completion: (@Sendable (CommandRequest) -> Void)?,
    subscriber: (@Sendable (Int32) -> Void)?
  ) throws {
    var handedOff = false
    defer { if !handedOff { Darwin.close(client) } }
    var completedRequest: CommandRequest?
    defer {
      if let completedRequest {
        completion?(completedRequest)
      }
    }
    do {
      let requestData = try readLine(from: client, limit: maximumIPCRequestBytes)
      let request = try JSONDecoder().decode(CommandRequest.self, from: requestData)
      if request.command == subscribeCommand, let subscriber {
        handedOff = true
        subscriber(client)
        return
      }
      completedRequest = request
      var data = try encodedResponseForIPC(handler(request))
      data.append(0x0A)
      try writeAll(data, to: client)
    } catch {
      var data = try encodedResponseForIPC(
        CommandResponse.failure(String(describing: error))
      )
      data.append(0x0A)
      try writeAll(data, to: client)
    }
  }
}

public func sendCommand(
  _ command: String,
  monitorIndex: Int? = nil,
  to url: URL = SocketPath.defaultURL
) throws -> CommandResponse {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw IPCError.systemCall("socket", errno)
  }
  defer { Darwin.close(descriptor) }

  try connectAndSend(
    CommandRequest(command: command, monitorIndex: monitorIndex),
    on: descriptor, to: url, readTimeout: true
  )
  let responseData = try readLine(from: descriptor, limit: maximumIPCResponseBytes)
  guard let response = try? JSONDecoder().decode(CommandResponse.self, from: responseData) else {
    throw IPCError.invalidResponse
  }
  return response
}

/// Streams `defi subscribe` lines to `output` until the daemon closes the connection.
public func subscribeToEvents(
  to url: URL = SocketPath.defaultURL,
  output: (Data) -> Void
) throws {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw IPCError.systemCall("socket", errno)
  }
  defer { Darwin.close(descriptor) }
  try connectAndSend(
    CommandRequest(command: subscribeCommand), on: descriptor, to: url, readTimeout: false
  )
  // A daemon without the stream answers with one failed command response.
  var firstLine: Data? = Data()
  var buffer = [UInt8](repeating: 0, count: 65_536)
  while true {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    if count < 0, errno == EINTR { continue }
    if count < 0 { throw IPCError.systemCall("read", errno) }
    if count == 0 { return }
    let chunk = Data(buffer[..<count])
    guard var line = firstLine else {
      output(chunk)
      continue
    }
    line.append(chunk)
    guard let newline = line.firstIndex(of: 0x0A) else {
      guard line.count <= maximumIPCResponseBytes else { throw IPCError.invalidResponse }
      firstLine = line
      continue
    }
    if let response = try? JSONDecoder().decode(CommandResponse.self, from: line[..<newline]) {
      throw IPCError.rejected(response.message)
    }
    firstLine = nil
    output(line)
  }
}

private func connectAndSend(
  _ request: CommandRequest,
  on descriptor: Int32,
  to url: URL,
  readTimeout: Bool
) throws {
  try configureNoSigPipe(descriptor)
  try withSocketAddress(path: url.path) { address, length in
    guard connect(descriptor, address, length) == 0 else {
      throw IPCError.systemCall("connect", errno)
    }
  }
  // Before the write: once the daemon has replied and closed, setsockopt fails.
  if readTimeout { try configureReadTimeout(descriptor) }
  var data = try JSONEncoder().encode(request)
  data.append(0x0A)
  try writeAll(data, to: descriptor)
}

private func withSocketAddress<Result>(
  path: String,
  body: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
) throws -> Result {
  let bytes = Array(path.utf8)
  var address = sockaddr_un()
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard bytes.count + 1 <= capacity else {
    throw IPCError.invalidSocketPath
  }
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
    buffer.copyBytes(from: bytes)
  }
  return try withUnsafePointer(to: &address) {
    try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
}

private func readLine(from descriptor: Int32, limit: Int) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while data.count <= limit {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    if count < 0 {
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        throw IPCError.readTimeout
      }
      throw IPCError.systemCall("read", errno)
    }
    if count == 0 { break }
    if let newline = buffer[..<count].firstIndex(of: 0x0A) {
      data.append(contentsOf: buffer[..<newline])
      return data
    }
    data.append(contentsOf: buffer[..<count])
  }
  guard data.count <= limit else {
    throw IPCError.requestTooLarge
  }
  return data
}

func configureNoSigPipe(_ descriptor: Int32) throws {
  var enabled: Int32 = 1
  guard
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &enabled,
      socklen_t(MemoryLayout<Int32>.size)
    ) == 0
  else {
    throw IPCError.systemCall("setsockopt", errno)
  }
}

func configureBlocking(_ descriptor: Int32) throws {
  let flags = fcntl(descriptor, F_GETFL)
  guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
    throw IPCError.systemCall("fcntl", errno)
  }
}

func configureReadTimeout(_ descriptor: Int32) throws {
  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  guard
    setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size)
    ) == 0
  else {
    throw IPCError.systemCall("setsockopt", errno)
  }
}

func writeAll(_ data: Data, to descriptor: Int32) throws {
  try data.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else { return }
    var written = 0
    while written < rawBuffer.count {
      let count = Darwin.write(
        descriptor,
        baseAddress.advanced(by: written),
        rawBuffer.count - written
      )
      if count < 0 {
        if errno == EINTR { continue }
        throw IPCError.systemCall("write", errno)
      }
      written += count
    }
  }
}
