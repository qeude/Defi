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
  public let kind: WorkspaceKind
  public let active: Bool
  public let windowCount: Int
  public let occupied: Bool
  public let applications: [String]
  public let focusedApplication: String?

  public init(
    id: String,
    position: Int,
    name: String?,
    kind: WorkspaceKind,
    active: Bool,
    windowCount: Int,
    applications: [String],
    focusedApplication: String?
  ) {
    self.id = id
    self.position = position
    self.name = name
    self.kind = kind
    self.active = active
    self.windowCount = windowCount
    self.occupied = windowCount > 0
    self.applications = applications
    self.focusedApplication = focusedApplication
  }
}

public func makeWorkspaceStateSnapshot(
  monitors: [Monitor],
  windows: [WindowID: Window],
  displayOrder: [MonitorID],
  focusedMonitorID: MonitorID?
) -> WorkspaceStateSnapshot {
  let monitorByID = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
  let orderedIDs =
    displayOrder.filter { monitorByID[$0] != nil }
    + monitors.map(\.id).filter { displayOrder.contains($0) == false }
  return WorkspaceStateSnapshot(
    focusedMonitorID: focusedMonitorID?.rawValue,
    monitors: orderedIDs.enumerated().compactMap { offset, monitorID in
      guard let monitor = monitorByID[monitorID] else { return nil }
      return MonitorWorkspaceSnapshot(
        id: monitor.id.rawValue,
        display: offset + 1,
        focused: monitor.id == focusedMonitorID,
        activeWorkspace: monitor.activeWorkspace.rawValue,
        workspaces: monitor.workspaces.enumerated().map { offset, workspace in
          let windowIDs = workspace.columns.flatMap(\.windows) + workspace.floatingWindows
          let workspaceWindows = windowIDs.compactMap { windows[$0] }
          let focusedWindowID: WindowID? = {
            guard workspace.id == monitor.activeWorkspace else { return nil }
            if workspace.focusedLayer == .floating,
              workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
            {
              return workspace.floatingWindows[workspace.focusedFloatingWindow]
            }
            guard workspace.columns.indices.contains(workspace.focusedColumn) else {
              return nil
            }
            let column = workspace.columns[workspace.focusedColumn]
            guard column.windows.indices.contains(column.focusedWindow) else { return nil }
            return column.windows[column.focusedWindow]
          }()
          return WorkspaceSnapshot(
            id: workspace.id.rawValue,
            position: offset + 1,
            name: workspace.name,
            kind: workspace.kind,
            active: workspace.id == monitor.activeWorkspace,
            windowCount: workspaceWindows.count,
            applications: Array(Set(workspaceWindows.map(\.appID))).sorted(),
            focusedApplication: focusedWindowID.flatMap { windows[$0]?.appID }
          )
        }
      )
    }
  )
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

private let maximumIPCMessageBytes = 65_536

func encodedResponseForIPC(_ response: CommandResponse) throws -> Data {
  let encoder = JSONEncoder()
  let encoded = try encoder.encode(response)
  guard encoded.count > maximumIPCMessageBytes else { return encoded }
  return try encoder.encode(CommandResponse.failure("IPC response too large"))
}

public enum IPCError: Error, CustomStringConvertible, Sendable {
  case invalidSocketPath
  case systemCall(String, Int32)
  case invalidResponse
  case requestTooLarge
  case readTimeout

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
    completion: (@Sendable (CommandRequest) -> Void)? = nil
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
        try? self.serve(client, handler: handler, completion: completion)
      }
    } else {
      try serve(client, handler: handler, completion: completion)
    }
    return true
  }

  private func serve(
    _ client: Int32,
    handler: @Sendable (CommandRequest) -> CommandResponse,
    completion: (@Sendable (CommandRequest) -> Void)?
  ) throws {
    defer { Darwin.close(client) }
    var completedRequest: CommandRequest?
    defer {
      if let completedRequest {
        completion?(completedRequest)
      }
    }
    do {
      let requestData = try readLine(from: client)
      let request = try JSONDecoder().decode(CommandRequest.self, from: requestData)
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

  try configureNoSigPipe(descriptor)
  try withSocketAddress(path: url.path) { address, length in
    guard connect(descriptor, address, length) == 0 else {
      throw IPCError.systemCall("connect", errno)
    }
  }
  try configureReadTimeout(descriptor)
  var request = try JSONEncoder().encode(
    CommandRequest(command: command, monitorIndex: monitorIndex)
  )
  request.append(0x0A)
  try writeAll(request, to: descriptor)
  let responseData = try readLine(from: descriptor)
  guard let response = try? JSONDecoder().decode(CommandResponse.self, from: responseData) else {
    throw IPCError.invalidResponse
  }
  return response
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

private func readLine(from descriptor: Int32) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while data.count <= 65_536 {
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
  guard data.count <= 65_536 else {
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
