@testable import DefiIPC
import Darwin
import Foundation
import Synchronization
import Testing
import XCTest

final class IPCTests: XCTestCase {
  func testProtocolRoundTrip() throws {
    let request = CommandRequest(command: "focus-column left")
    let requestData = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(CommandRequest.self, from: requestData), request)

    let response = CommandResponse.success("moved")
    let responseData = try JSONEncoder().encode(response)
    XCTAssertEqual(
      try JSONDecoder().decode(CommandResponse.self, from: responseData),
      response
    )
  }

  func testDefaultSocketPathIsPerUser() {
    XCTAssertTrue(SocketPath.defaultURL.lastPathComponent.hasPrefix("defi-"))
    XCTAssertEqual(SocketPath.defaultURL.pathExtension, "sock")
  }

  func testClosedPeerReturnsBrokenPipeInsteadOfTerminatingProcess() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
      if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
    }
    try configureNoSigPipe(descriptors[0])
    Darwin.close(descriptors[1])
    descriptors[1] = -1

    XCTAssertThrowsError(try writeAll(Data("request\n".utf8), to: descriptors[0])) {
      guard case IPCError.systemCall("write", EPIPE) = $0 else {
        return XCTFail("expected EPIPE, got \($0)")
      }
    }
  }

  func testAcceptedClientCanBeRestoredToBlockingMode() throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { Darwin.close(descriptor) }
    let flags = fcntl(descriptor, F_GETFL)
    XCTAssertEqual(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), 0)

    try configureBlocking(descriptor)

    XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_NONBLOCK, 0)
  }

  func testReadTimeoutIsConfigured() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
    defer {
      if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
      if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
    }

    try configureReadTimeout(descriptors[0])

    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    var length = socklen_t(MemoryLayout<timeval>.size)
    XCTAssertEqual(
      getsockopt(
        descriptors[0],
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        &length
      ),
      0
    )
    XCTAssertGreaterThan(timeout.tv_sec, 0)
  }
}

struct IPCCompletionTests {
  @Test
  func asynchronousCompletionRunsAfterTheRequestHandler() async throws {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "defi-ipc-\(UUID().uuidString).sock")
    let server = try UnixSocketServer(url: url)
    let clientQueue = DispatchQueue(label: "defi.ipc.tests")
    let handlerFinished = Mutex(false)
    let (completionEvents, completionEventsContinuation) =
      AsyncStream<Bool>.makeStream()
    let responseTask = Task.detached {
      try sendCommand("quit", to: url)
    }

    var accepted = false
    for _ in 0..<100 where accepted == false {
      accepted = try server.poll(
        on: clientQueue,
        handler: { request in
          handlerFinished.withLock { $0 = true }
          return .success(request.command)
        },
        completion: { request in
          completionEventsContinuation.yield(
            handlerFinished.withLock { $0 } && request.command == "quit"
          )
          completionEventsContinuation.finish()
        }
      )
      if accepted == false {
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    #expect(accepted)
    #expect(try await responseTask.value == .success("quit"))
    var completionIterator = completionEvents.makeAsyncIterator()
    #expect(await completionIterator.next() == true)
  }

  @Test
  func oversizedResponseIsTruncatedWithinTheProtocolLimit() throws {
    let original = CommandResponse.success(
      String(repeating: "trace \\\"value\\\"\n", count: 8_000)
    )

    let data = try encodedResponseForIPC(original)
    let decoded = try JSONDecoder().decode(CommandResponse.self, from: data)

    #expect(data.count <= 65_536)
    #expect(decoded.ok)
    #expect(decoded.message.hasPrefix("[truncated]\n"))
    #expect(original.message.hasSuffix(decoded.message.dropFirst("[truncated]\n".count)))
  }
}
