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

  func testPreviousWindowIDSurvivesMissingCGSnapshotRecord() {
    XCTAssertEqual(
      resolvedCGWindowID(
        matchedRecord: nil,
        preferredWindowID: WindowID(rawValue: 42)
      ),
      42
    )
  }

  func testStandardClosableResizableWindowIsTiled() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ),
      .tiled
    )
  }

  func testControlLessPictureInPictureWindowFloats() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: false,
        forceTiling: false
      ),
      .floating
    )
  }

  func testSystemDialogsAndSheetsFloatByDefault() {
    for (role, subrole) in [
      (kAXWindowRole, "AXSystemDialog"),
      (kAXWindowRole, "AXFloatingWindow"),
      (kAXSheetRole, nil),
    ] {
      XCTAssertEqual(
        classifyWindow(
          role: role,
          subrole: subrole,
          appID: "com.example.app",
          hasCloseButton: false,
          canResize: false,
          configuredFloating: false,
          forceTiling: false
        ),
        .floating
      )
    }
  }

  func testConfiguredFloatingTracksUnknownAuxiliaryWindow() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXUnknownSubrole,
        appID: "com.example.app",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: true,
        forceTiling: false
      ),
      .floating
    )
  }

  func testTransientCloseButtonFailurePreservesManagedWindow() {
    XCTAssertTrue(
      shouldTreatWindowAsClosable(
        error: .cannotComplete,
        hasValue: false,
        wasPreviouslyManaged: true
      )
    )
    XCTAssertFalse(
      shouldTreatWindowAsClosable(
        error: .cannotComplete,
        hasValue: false,
        wasPreviouslyManaged: false
      )
    )
  }

  func testTransientMetadataFailureDefersNewStandardWindow() {
    XCTAssertTrue(
      shouldDeferStandardWindowClassification(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        closeButtonError: .cannotComplete,
        sizeSettableError: .success,
        wasPreviouslyTracked: false
      )
    )
    XCTAssertFalse(
      shouldDeferStandardWindowClassification(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        closeButtonError: .cannotComplete,
        sizeSettableError: .success,
        wasPreviouslyTracked: true
      )
    )
  }

  func testUnsupportedSizeAttributeMeansFixedSize() {
    XCTAssertFalse(
      windowCanResize(
        sizeSettableError: .attributeUnsupported,
        isSettable: false
      )
    )
    XCTAssertTrue(
      windowCanResize(
        sizeSettableError: .cannotComplete,
        isSettable: false
      )
    )
  }

  func testMissingCloseButtonRemainsUnmanaged() {
    XCTAssertFalse(
      shouldTreatWindowAsClosable(
        error: .noValue,
        hasValue: false,
        wasPreviouslyManaged: true
      )
    )
  }

  func testForceTilingOverridesWindowShapeFilter() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXUnknownSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: false,
        forceTiling: true
      ),
      .tiled
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

  func testFrontmostSingleWindowDefersSelectionToAsyncValidation() {
    XCTAssertFalse(
      shouldSelectSpecificWindow(
        activatesApplication: false,
        hasUnmanagedAuxiliaryWindows: true,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      )
    )
  }
}
