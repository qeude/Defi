import ApplicationServices
import DefiModel
import XCTest

@testable import DefiMacOS

final class WindowDiscoveryTests: XCTestCase {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 2_554, height: 1_354)

  func testWindowMatchingPrefersExactFrameOverEmptyTitle() {
    let exactFrame = CGWindowRecord(
      id: 1,
      processID: processID,
      title: "WhatsApp 🔊",
      frame: frame
    )
    let emptyTitleStrip = CGWindowRecord(
      id: 2,
      processID: processID,
      title: "",
      frame: Rect(x: 0, y: 0, width: 2_560, height: 30)
    )

    let match = bestCGWindow(
      processID: processID,
      title: "WhatsApp - Helium",
      frame: frame,
      records: [emptyTitleStrip, exactFrame]
    )

    XCTAssertEqual(match?.id, exactFrame.id)
  }

  func testWindowMatchingRejectsUnrelatedSurface() {
    let unrelated = CGWindowRecord(
      id: 1,
      processID: processID,
      title: "",
      frame: Rect(x: 104, y: 34, width: 2_554, height: 1_354)
    )

    XCTAssertNil(
      bestCGWindow(
        processID: processID,
        title: "Picture in Picture",
        frame: frame,
        records: [unrelated]
      )
    )
  }

  func testWindowMatchingUsesTitleToBreakGeometryTie() {
    let wrongTitle = CGWindowRecord(
      id: 1,
      processID: processID,
      title: "Other",
      frame: frame
    )
    let matchingTitle = CGWindowRecord(
      id: 2,
      processID: processID,
      title: "Window",
      frame: frame
    )

    let match = bestCGWindow(
      processID: processID,
      title: "Window",
      frame: frame,
      records: [wrongTitle, matchingTitle]
    )

    XCTAssertEqual(match?.id, matchingTitle.id)
  }

  func testStandardClosableWindowIsManaged() {
    XCTAssertTrue(
      shouldManageWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: true,
        forceTiling: false
      )
    )
  }

  func testControlLessPictureInPictureWindowIsUnmanaged() {
    XCTAssertFalse(
      shouldManageWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        forceTiling: false
      )
    )
  }

  func testForceTilingOverridesWindowShapeFilter() {
    XCTAssertTrue(
      shouldManageWindow(
        role: kAXWindowRole,
        subrole: kAXUnknownSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        forceTiling: true
      )
    )
  }

  func testApplicationActivationSelectsTargetWithUnmanagedAuxiliaryWindows() {
    XCTAssertTrue(
      shouldSelectSpecificWindow(
        activatesApplication: true,
        hasUnmanagedAuxiliaryWindows: true,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      )
    )
  }

  func testStableSingleWindowFocusKeepsFastPath() {
    XCTAssertFalse(
      shouldSelectSpecificWindow(
        activatesApplication: true,
        hasUnmanagedAuxiliaryWindows: false,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      )
    )
  }
}
