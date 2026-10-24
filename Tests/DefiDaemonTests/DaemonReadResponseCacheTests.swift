import DefiIPC
import Testing

@testable import DefiDaemon

struct DaemonReadResponseCacheTests {
  @Test
  func `Read responses are served per command until they expire`() {
    let cache = DaemonReadResponseCache(maxAge: 0.25)
    #expect(cache.response(for: "status", now: 10) == nil)
    cache.store(message: "running", for: "status", now: 10)
    cache.store(message: "events", for: "trace", now: 10)
    #expect(cache.response(for: "status", now: 10.2) == .success("running"))
    #expect(cache.response(for: "trace", now: 10.2) == .success("events"))
    #expect(cache.response(for: "list-workspaces", now: 10.2) == nil)
    #expect(cache.response(for: "status", now: 10.26) == nil)
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
