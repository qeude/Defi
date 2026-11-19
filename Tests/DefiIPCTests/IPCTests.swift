import Darwin
import Foundation
import Synchronization
import Testing

@testable import DefiIPC

struct IPCTests {
  @Test
  func `Closed peer returns broken pipe instead of terminating process`() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer {
      if descriptors[0] >= 0 { Darwin.close(descriptors[0]) }
      if descriptors[1] >= 0 { Darwin.close(descriptors[1]) }
    }
    try configureNoSigPipe(descriptors[0])
    Darwin.close(descriptors[1])
    descriptors[1] = -1

    let capturedError = #expect(throws: IPCError.self) {
      try writeAll(Data("request\n".utf8), to: descriptors[0])
    }
    let error = try #require(capturedError)
    guard case IPCError.systemCall("write", EPIPE) = error else {
      Issue.record("expected EPIPE, got \(error)")
      return
    }
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
    // Blocking socket calls stay off the cooperative pool, which a small CI runner can exhaust.
    let response = Mutex<Result<CommandResponse, any Error>?>(nil)
    let responseReceived = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      response.withLock { $0 = Result { try sendCommand("quit", to: url) } }
      responseReceived.signal()
    }

    let descriptor = server.listeningFileDescriptor
    let connected = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        var listening = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        continuation.resume(returning: Darwin.poll(&listening, 1, 5_000) == 1)
      }
    }
    #expect(connected, "the client never connected")
    let accepted = try server.poll(
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

    #expect(accepted)
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { responseReceived.wait(); continuation.resume() }
    }
    #expect(try response.withLock { $0 }?.get() == .success("quit"))
    var completionIterator = completionEvents.makeAsyncIterator()
    #expect(await completionIterator.next() == true)
  }

  @Test
  func oversizedResponseFailsWithinTheProtocolLimit() throws {
    let original = CommandResponse.success(
      String(repeating: "trace \\\"value\\\"\n", count: 300_000)
    )

    let data = try encodedResponseForIPC(original)
    let decoded = try JSONDecoder().decode(CommandResponse.self, from: data)

    #expect(data.count <= maximumIPCResponseBytes)
    #expect(decoded == .failure("IPC response too large"))
  }
}
