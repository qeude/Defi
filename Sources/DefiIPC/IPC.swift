import Darwin
import Foundation

public struct CommandRequest: Codable, Equatable, Sendable {
  public let command: String

  public init(command: String) {
    self.command = command
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

public final class UnixSocketServer {
  public let url: URL
  private let descriptor: Int32

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
    handler: (String) -> CommandResponse
  ) throws -> Bool {
    let client = accept(descriptor, nil, nil)
    if client < 0 {
      if errno == EAGAIN || errno == EWOULDBLOCK {
        return false
      }
      throw IPCError.systemCall("accept", errno)
    }
    defer { Darwin.close(client) }

    do {
      try configureNoSigPipe(client)
      try configureBlocking(client)
      try configureReadTimeout(client)
      let requestData = try readLine(from: client)
      let request = try JSONDecoder().decode(CommandRequest.self, from: requestData)
      let response = handler(request.command)
      var data = try JSONEncoder().encode(response)
      data.append(0x0A)
      try writeAll(data, to: client)
    } catch {
      var data = try JSONEncoder().encode(CommandResponse.failure(String(describing: error)))
      data.append(0x0A)
      try writeAll(data, to: client)
    }
    return true
  }
}

public func sendCommand(
  _ command: String,
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
  var request = try JSONEncoder().encode(CommandRequest(command: command))
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
