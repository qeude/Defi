import DefiIPC
import XCTest

@testable import DefiDaemon

final class DaemonReadResponseCacheTests: XCTestCase {
  func testStoresAndServesReadResponsesWithinTTL() {
    let cache = DaemonReadResponseCache(maxAge: 0.25)

    XCTAssertNil(cache.response(for: "status", now: 10))
    cache.store(message: "running", for: "status", now: 10)

    XCTAssertEqual(
      cache.response(for: "status", now: 10.2),
      .success("running")
    )
  }

  func testExpiresResponsesAfterTTL() {
    let cache = DaemonReadResponseCache(maxAge: 0.25)
    cache.store(message: "running", for: "status", now: 10)

    XCTAssertNil(cache.response(for: "status", now: 10.26))
  }

  func testKeysAreIsolatedPerCommand() {
    let cache = DaemonReadResponseCache(maxAge: 1)
    cache.store(message: "a", for: "status", now: 10)
    cache.store(message: "b", for: "trace", now: 10)

    XCTAssertEqual(
      cache.response(for: "status", now: 10.5),
      .success("a")
    )
    XCTAssertEqual(
      cache.response(for: "trace", now: 10.5),
      .success("b")
    )
    XCTAssertNil(cache.response(for: "list-workspaces", now: 10.5))
  }

  func testOnlyReadCommandsAreCacheable() {
    XCTAssertTrue(DaemonReadResponseCache.isReadCommand("status"))
    XCTAssertTrue(DaemonReadResponseCache.isReadCommand("list-workspaces --json"))
    XCTAssertFalse(DaemonReadResponseCache.isReadCommand("focus-column left"))
    XCTAssertFalse(DaemonReadResponseCache.isReadCommand("quit"))
  }
}
