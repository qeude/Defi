import DefiIPC
import Testing

@testable import DefiDaemon

struct DaemonReadResponseCacheTests {
  @Test
  func `Stores and serves read responses within TTL`() {
    let cache = DaemonReadResponseCache(maxAge: 0.25)

    #expect(cache.response(for: "status", now: 10) == nil)
    cache.store(message: "running", for: "status", now: 10)

    #expect(cache.response(for: "status", now: 10.2) == .success("running"))
  }

  @Test
  func `Expires responses after TTL`() {
    let cache = DaemonReadResponseCache(maxAge: 0.25)
    cache.store(message: "running", for: "status", now: 10)

    #expect(cache.response(for: "status", now: 10.26) == nil)
  }

  @Test
  func `Keys are isolated per command`() {
    let cache = DaemonReadResponseCache(maxAge: 1)
    cache.store(message: "a", for: "status", now: 10)
    cache.store(message: "b", for: "trace", now: 10)

    #expect(cache.response(for: "status", now: 10.5) == .success("a"))
    #expect(cache.response(for: "trace", now: 10.5) == .success("b"))
    #expect(cache.response(for: "list-workspaces", now: 10.5) == nil)
  }

  @Test(arguments: [
    ("status", true),
    ("list-workspaces --json", true),
    ("focus-column left", false),
    ("quit", false),
  ])
  func `Only read commands are cacheable`(
    testCase: (command: String, expected: Bool)
  ) {
    #expect(
      DaemonReadResponseCache.isReadCommand(testCase.command)
        == testCase.expected
    )
  }
}
