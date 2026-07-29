import ApplicationServices
import DefiConfig
import XCTest

@testable import DefiMacOS

final class HotKeyTests: XCTestCase {
  private let aliases = [
    "hyper": "Alt + Cmd + Ctrl"
  ]

  func testHyperArrowUsesExpectedKeyCodeAndModifiers() throws {
    let key = try Key(accelerator: "hyper-left", aliases: aliases)

    XCTAssertEqual(key.code, 123)
    XCTAssertEqual(
      key.modifierBits,
      CGEventFlags([
        .maskAlternate,
        .maskCommand,
        .maskControl,
      ]).rawValue
    )
  }

  func testHyperShiftWorkspaceUsesExpectedKeyCodeAndModifiers() throws {
    let key = try Key(accelerator: "hyper-shift-1", aliases: aliases)

    XCTAssertEqual(key.code, 18)
    XCTAssertEqual(
      key.modifierBits,
      CGEventFlags([
        .maskAlternate,
        .maskCommand,
        .maskControl,
        .maskShift,
      ]).rawValue
    )
  }
}
