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

  func testHyperResizeKeysUseExpectedKeyCodesAndModifiers() throws {
    let expectedModifierBits = CGEventFlags([
      .maskAlternate,
      .maskCommand,
      .maskControl,
    ]).rawValue

    let cases: [(accelerator: String, code: CGKeyCode)] = [
      ("hyper-equal", 24),
      ("hyper-minus", 27),
      ("hyper-f", 3),
    ]
    for (accelerator, code) in cases {
      let key = try Key(accelerator: accelerator, aliases: aliases)
      XCTAssertEqual(key.code, code)
      XCTAssertEqual(key.modifierBits, expectedModifierBits)
    }
  }
}
