import ApplicationServices
import DefiModel
import Testing
import XCTest

@testable import DefiMacOS

final class WindowDiscoveryTests: XCTestCase {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 2_554, height: 1_354)

  func testTransientWindowOmissionExpiresAfterGracePeriod() {
    let windowID = WindowID(rawValue: 42)
    let first = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: [:],
      now: 10,
      gracePeriod: 0.75
    )
    XCTAssertEqual(first.windowIDs, [windowID])
    XCTAssertEqual(first.deadlines[windowID], 10.75)

    let pending = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: first.deadlines,
      now: 10.7,
      gracePeriod: 0.75
    )
    XCTAssertEqual(pending.windowIDs, [windowID])

    let expired = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: first.deadlines,
      now: 10.75,
      gracePeriod: 0.75
    )
    XCTAssertTrue(expired.windowIDs.isEmpty)
    XCTAssertTrue(expired.deadlines.isEmpty)
  }

  func testTransientProcessDisagreementDefersFocusResolution() {
    XCTAssertNil(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: 7
      )
    )
  }

  func testAccessibilityProcessIsFallbackWithoutFrontmostApplication() {
    XCTAssertEqual(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: nil
      ),
      42
    )
  }

  func testMatchingFrontmostAndAccessibilityProcessesResolveFocus() {
    XCTAssertEqual(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: 42
      ),
      42
    )
  }

  func testFocusedAuxiliaryWindowDoesNotSelectDistantManagedWindow() {
    let managed = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )

    XCTAssertNil(
      focusedWindowIDMatchingFrame(
        processID: processID,
        focusedFrame: Rect(x: 400, y: 300, width: 500, height: 300),
        windows: [managed]
      )
    )
  }

  func testFocusedManagedWindowMatchesSmallSnapshotFrameDrift() {
    let managed = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )

    XCTAssertEqual(
      focusedWindowIDMatchingFrame(
        processID: processID,
        focusedFrame: Rect(
          x: frame.x + 2,
          y: frame.y,
          width: frame.width,
          height: frame.height
        ),
        windows: [managed]
      ),
      managed.id
    )
  }

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

  func testFocusRecoveryMatchesUnmanagedAuxiliaryWindowByFrame() {
    let auxiliaryFrame = Rect(x: 400, y: 300, width: 500, height: 300)

    XCTAssertEqual(
      closestFocusRecoveryWindowIndex(
        target: (auxiliaryFrame, "Preferences"),
        candidates: [(frame, "Main"), (auxiliaryFrame, "Preferences")]
      ),
      1
    )
  }

  func testFocusRecoverySearchesBeyondFirst32Candidates() {
    let targetFrame = Rect(x: 400, y: 300, width: 500, height: 300)
    var candidates = Array(
      repeating: (Rect(x: 0, y: 0, width: 100, height: 100), "Other"),
      count: 32
    )
    candidates.append((targetFrame, "Preferences"))

    XCTAssertEqual(
      closestFocusRecoveryWindowIndex(
        target: (targetFrame, "Preferences"),
        candidates: candidates
      ),
      32
    )
  }

  func testFocusRecoveryRejectsDistantAccessibilityWindow() {
    XCTAssertNil(
      closestFocusRecoveryWindowIndex(
        target: (
          Rect(x: 400, y: 300, width: 500, height: 300),
          "Preferences"
        ),
        candidates: [(frame, "Main")]
      )
    )
  }

  func testFocusRecoveryUsesTitleToBreakGeometryTie() {
    let auxiliaryFrame = Rect(x: 400, y: 300, width: 500, height: 300)

    XCTAssertEqual(
      closestFocusRecoveryWindowIndex(
        target: (auxiliaryFrame, "Preferences"),
        candidates: [
          (auxiliaryFrame, "Main"),
          (auxiliaryFrame, "Preferences"),
        ]
      ),
      1
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

  func testPreferredWindowIDRequiresLiveCGRecordFromSameProcess() {
    let live = CGWindowRecord(
      id: 42,
      processID: processID,
      layer: 0,
      title: "Window",
      frame: frame
    )
    let recycledByAnotherProcess = CGWindowRecord(
      id: 42,
      processID: 7,
      layer: 0,
      title: "Other",
      frame: frame
    )

    XCTAssertEqual(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [live],
        excluding: []
      )?.id,
      42
    )
    XCTAssertNil(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [],
        excluding: []
      )
    )
    XCTAssertNil(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [recycledByAnotherProcess],
        excluding: []
      )
    )
    XCTAssertNil(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [live],
        excluding: [42]
      )
    )
  }

  func testMissingPreferredWindowRecordDoesNotRematchUnrelatedLiveWindow() {
    let otherLiveWindow = CGWindowRecord(
      id: 43,
      processID: processID,
      layer: 0,
      title: "Window",
      frame: frame
    )

    XCTAssertNil(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [otherLiveWindow],
        excluding: []
      )
    )
    XCTAssertEqual(
      cgWindowRecordForDiscovery(
        preferredWindowID: nil,
        processID: processID,
        title: "Window",
        frame: frame,
        records: [otherLiveWindow],
        excluding: []
      )?.id,
      43
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
    XCTAssertEqual(
      eligibleCGWindowRecords(
        role: kAXWindowRole,
        for: kAXUnknownSubrole,
        allowsConfiguredNonzeroLayer: true,
        in: [normal, panel]
      ).map(\.id),
      [normal.id, panel.id]
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

  func testModalStandardWindowFloatsEvenWhenResizable() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "com.example.app",
        hasCloseButton: true,
        canResize: true,
        isModal: true,
        configuredFloating: false,
        forceTiling: false
      ),
      .floating
    )
  }

  func testQuickLookServiceWindowFloatsEvenWhenStandard() {
    XCTAssertEqual(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "com.apple.quicklook.QuickLookUIService",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ),
      .floating
    )
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
      (nil, WindowDisposition.unavailable),
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

  func testTransientModalReadPreservesCachedValue() {
    XCTAssertEqual(
      resolvedWindowModalState(
        error: .cannotComplete,
        observedValue: nil,
        cachedValue: true
      ),
      true
    )
    XCTAssertNil(
      resolvedWindowModalState(
        error: .cannotComplete,
        observedValue: nil,
        cachedValue: nil
      )
    )
    XCTAssertEqual(
      resolvedWindowModalState(
        error: .attributeUnsupported,
        observedValue: nil,
        cachedValue: true
      ),
      false
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

struct WindowClassificationReviewFeedbackTests {
  @Test func successfulSiblingDoesNotClearFailingElementRetries() {
    let processID: pid_t = 42
    let failing = AXWindowElementIdentity(
      processID: processID,
      element: AXUIElementCreateApplication(processID)
    )
    let successful = AXWindowElementIdentity(
      processID: processID,
      element: AXUIElementCreateSystemWide()
    )
    var failures = [failing: 2]

    failures[successful] = nil

    #expect(failures[failing] == 2)
  }

  @Test func repeatedBatchFailuresDisableBatchedAttributeReads() {
    #expect(!shouldDisableBatchedWindowAttributeReads(failureCount: 1))
    #expect(!shouldDisableBatchedWindowAttributeReads(failureCount: 2))
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 3))
  }

  @Test func quickLookRuleMatchesOnlyAppleServiceBundleID() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "COM.APPLE.QUICKLOOK.QUICKLOOKUISERVICE",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ) == .floating
    )
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "com.example.quicklook.editor",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ) == .tiled
    )
  }
}
