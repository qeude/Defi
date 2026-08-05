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
      layer: 0,
      title: "WhatsApp 🔊",
      frame: frame
    )
    let emptyTitleStrip = CGWindowRecord(
      id: 2,
      processID: processID,
      layer: 0,
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
      layer: 0,
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
      layer: 0,
      title: "Other",
      frame: frame
    )
    let matchingTitle = CGWindowRecord(
      id: 2,
      processID: processID,
      layer: 0,
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

  func testAuxiliaryRolesCanMatchFloatingLevelWindowRecords() {
    let normal = CGWindowRecord(
      id: 1,
      processID: processID,
      layer: 0,
      title: "Main",
      frame: frame
    )
    let panel = CGWindowRecord(
      id: 2,
      processID: processID,
      layer: 3,
      title: "Utility",
      frame: frame
    )

    for (role, subrole) in [
      (kAXWindowRole, "AXDialog"),
      (kAXWindowRole, "AXFloatingWindow"),
      (kAXWindowRole, "AXSystemDialog"),
      (kAXWindowRole, "AXSystemFloatingWindow"),
      (kAXSheetRole, nil),
    ] {
      XCTAssertEqual(
        eligibleCGWindowRecords(
          role: role,
          for: subrole,
          in: [normal, panel]
        ).map(\.id),
        [normal.id, panel.id]
      )
    }
    XCTAssertEqual(
      eligibleCGWindowRecords(
        role: kAXWindowRole,
        for: kAXStandardWindowSubrole,
        in: [normal, panel]
      ).map(\.id),
      [normal.id]
    )
  }

  func testWindowFrameSnapshotSelectsRequestedFloatingWindow() {
    let requested = CGWindowRecord(
      id: 2,
      processID: processID,
      layer: 3,
      title: "Utility",
      frame: frame
    )
    let unrelated = CGWindowRecord(
      id: 3,
      processID: processID,
      layer: 0,
      title: "Main",
      frame: Rect(x: 100, y: 100, width: 800, height: 600)
    )

    XCTAssertEqual(
      framesByWindowID(
        for: [WindowID(rawValue: UInt64(requested.id))],
        in: [unrelated, requested]
      ),
      [WindowID(rawValue: UInt64(requested.id)): frame]
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

  func testTransientMetadataFailurePreservesPreviousDisposition() {
    let cases: [(WindowDisposition?, WindowDisposition)] = [
      (nil, WindowDisposition.ignored),
      (.tiled, .tiled),
      (.floating, .floating),
    ]
    for (closeButtonError, sizeSettableError) in [
      (AXError.cannotComplete, AXError.success),
      (.success, .cannotComplete),
    ] {
      for (previous, expected) in cases {
        XCTAssertEqual(
          fallbackDispositionForTransientWindowMetadata(
            role: kAXWindowRole,
            subrole: kAXStandardWindowSubrole,
            closeButtonError: closeButtonError,
            sizeSettableError: sizeSettableError,
            previousDisposition: previous
          ),
          expected
        )
      }
    }
    XCTAssertNil(
      fallbackDispositionForTransientWindowMetadata(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        closeButtonError: .success,
        sizeSettableError: .success,
        previousDisposition: .floating
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
