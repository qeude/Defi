@testable import DefiIPC
import Darwin
import Foundation
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
}
