import ApplicationServices
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowDiscoveryTests {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 2_554, height: 1_354)

  @Test
  func `Transient window omission expires after grace period`() {
    let windowID = WindowID(rawValue: 42)
    let first = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: [:],
      now: 10,
      gracePeriod: 0.75
    )
    #expect(first.windowIDs == [windowID])
    #expect(first.deadlines[windowID] == 10.75)

    let pending = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: first.deadlines,
      now: 10.7,
      gracePeriod: 0.75
    )
    #expect(pending.windowIDs == [windowID])

    let expired = retainedWindowIDsWithinGracePeriod(
      [windowID],
      previousDeadlines: first.deadlines,
      now: 10.75,
      gracePeriod: 0.75
    )
    #expect(expired.windowIDs.isEmpty)
    #expect(expired.deadlines.isEmpty)
  }

  @Test
  func `Transient process disagreement defers focus resolution`() {
    #expect(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: 7
      ) == nil)
  }

  @Test
  func `Frontmost native focus event overrides stale accessibility process`() {
    #expect(
      consistentFocusedProcessID(
        accessibilityProcessID: 7,
        frontmostProcessID: 42,
        verifiedNativeFocusProcessID: 42
      ) == 42)
  }

  @Test
  func `Accessibility process is fallback without frontmost application`() {
    #expect(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: nil
      ) == 42)
  }

  @Test
  func `Matching frontmost and accessibility processes resolve focus`() {
    #expect(
      consistentFocusedProcessID(
        accessibilityProcessID: 42,
        frontmostProcessID: 42
      ) == 42)
  }

  @MainActor
  @Test
  func `Pending native focus reuses stable window only after process verification`() {
    let platform = MacOSPlatform()
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )
    platform.lastFocusedWindowByProcess[processID] = window.id

    #expect(platform.stableWindowID(processID: processID, in: [window]) == window.id)

    platform.nativeFocusEventPending = true
    #expect(platform.stableWindowID(processID: processID, in: [window]) == nil)
    #expect(
      platform.stableWindowID(
        processID: processID,
        in: [window],
        allowPendingNativeFocus: true
      ) == window.id)
  }

  @MainActor
  @Test
  func `Pending native focus accepts verified single window fallback`() {
    let platform = MacOSPlatform()
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )
    platform.nativeFocusEventPending = true
    platform.nativeFocusEventProcessIDs = [processID]

    #expect(platform.stableWindowID(processID: processID, in: [window]) == window.id)
  }

  @Test
  func `Focused auxiliary window does not select distant managed window`() {
    let managed = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )

    #expect(
      focusedWindowIDMatchingFrame(
        processID: processID,
        focusedFrame: Rect(x: 400, y: 300, width: 500, height: 300),
        windows: [managed]
      ) == nil)
  }

  @Test
  func `Focused managed window matches small snapshot frame drift`() {
    let managed = Window(
      id: WindowID(rawValue: 1),
      appID: "com.example.app",
      title: "Main",
      frame: frame,
      processID: processID,
      monitorID: MonitorID(rawValue: 1)
    )

    #expect(
      focusedWindowIDMatchingFrame(
        processID: processID,
        focusedFrame: Rect(
          x: frame.x + 2,
          y: frame.y,
          width: frame.width,
          height: frame.height
        ),
        windows: [managed]
      ) == managed.id)
  }

  @Test
  func `Window matching prefers exact frame over empty title`() {
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

    #expect(match?.id == exactFrame.id)
  }

  @Test
  func `Window matching rejects unrelated surface`() {
    let unrelated = CGWindowRecord(
      id: 1,
      processID: processID,
      layer: 0,
      title: "",
      frame: Rect(x: 104, y: 34, width: 2_554, height: 1_354)
    )

    #expect(
      bestCGWindow(
        processID: processID,
        title: "Picture in Picture",
        frame: frame,
        records: [unrelated]
      ) == nil)
  }

  @Test
  func `Focus recovery matches unmanaged auxiliary window by frame`() {
    let auxiliaryFrame = Rect(x: 400, y: 300, width: 500, height: 300)

    #expect(
      closestFocusRecoveryWindowIndex(
        target: (auxiliaryFrame, "Preferences"),
        candidates: [(frame, "Main"), (auxiliaryFrame, "Preferences")]
      ) == 1)
  }

  @Test
  func `Focus recovery searches beyond first 32 candidates`() {
    let targetFrame = Rect(x: 400, y: 300, width: 500, height: 300)
    var candidates = Array(
      repeating: (Rect(x: 0, y: 0, width: 100, height: 100), "Other"),
      count: 32
    )
    candidates.append((targetFrame, "Preferences"))

    #expect(
      closestFocusRecoveryWindowIndex(
        target: (targetFrame, "Preferences"),
        candidates: candidates
      ) == 32)
  }

  @Test
  func `Focus recovery rejects distant accessibility window`() {
    #expect(
      closestFocusRecoveryWindowIndex(
        target: (
          Rect(x: 400, y: 300, width: 500, height: 300),
          "Preferences"
        ),
        candidates: [(frame, "Main")]
      ) == nil)
  }

  @Test
  func `Focus recovery uses title to break geometry tie`() {
    let auxiliaryFrame = Rect(x: 400, y: 300, width: 500, height: 300)

    #expect(
      closestFocusRecoveryWindowIndex(
        target: (auxiliaryFrame, "Preferences"),
        candidates: [
          (auxiliaryFrame, "Main"),
          (auxiliaryFrame, "Preferences"),
        ]
      ) == 1)
  }

  @Test
  func `Window matching uses title to break geometry tie`() {
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

    #expect(match?.id == matchingTitle.id)
  }

  @Test
  func `Preferred window ID requires live CG record from same process`() {
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

    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [live],
        excluding: []
      )?.id == 42)
    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [],
        excluding: []
      ) == nil)
    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [recycledByAnotherProcess],
        excluding: []
      ) == nil)
    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [live],
        excluding: [42]
      ) == nil)
  }

  @Test
  func `AX window ID bypasses redacted window server geometry`() {
    let live = CGWindowRecord(
      id: 42,
      processID: processID,
      layer: 0,
      title: "",
      frame: Rect(x: 0, y: 940, width: 500, height: 500)
    )

    #expect(
      cgWindowRecordForDiscovery(
        axWindowID: 42,
        preferredWindowID: nil,
        processID: processID,
        title: "Window",
        frame: frame,
        records: [live],
        excluding: []
      )?.id == 42)
  }

  @Test
  func `Missing preferred window record does not rematch unrelated live window`() {
    let otherLiveWindow = CGWindowRecord(
      id: 43,
      processID: processID,
      layer: 0,
      title: "Window",
      frame: frame
    )

    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: WindowID(rawValue: 42),
        processID: processID,
        title: "Window",
        frame: frame,
        records: [otherLiveWindow],
        excluding: []
      ) == nil)
    #expect(
      cgWindowRecordForDiscovery(
        preferredWindowID: nil,
        processID: processID,
        title: "Window",
        frame: frame,
        records: [otherLiveWindow],
        excluding: []
      )?.id == 43)
  }

  @Test(arguments: [
    (kAXWindowRole, Optional("AXDialog"), false, true),
    (kAXWindowRole, Optional("AXFloatingWindow"), false, true),
    (kAXWindowRole, Optional("AXSystemDialog"), false, true),
    (kAXWindowRole, Optional("AXSystemFloatingWindow"), false, true),
    (kAXSheetRole, nil, false, true),
    (kAXWindowRole, Optional(kAXStandardWindowSubrole), false, false),
    (kAXWindowRole, Optional(kAXUnknownSubrole), true, true),
  ])
  func `Window roles select eligible window server layers`(
    testCase: (
      role: String,
      subrole: String?,
      allowsConfiguredNonzeroLayer: Bool,
      includesPanel: Bool
    )
  ) {
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

    let expected =
      testCase.includesPanel
      ? [normal.id, panel.id]
      : [normal.id]

    #expect(
      eligibleCGWindowRecords(
        role: testCase.role,
        for: testCase.subrole,
        allowsConfiguredNonzeroLayer: testCase.allowsConfiguredNonzeroLayer,
        in: [normal, panel]
      ).map(\.id) == expected)
  }

  @Test
  func `Window frame snapshot selects requested floating window`() {
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

    #expect(
      framesByWindowID(
        for: [WindowID(rawValue: UInt64(requested.id))],
        in: [unrelated, requested]
      ) == [WindowID(rawValue: UInt64(requested.id)): frame])
  }

  @Test
  func `Standard closable resizable window is tiled`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ) == .tiled)
  }

  @Test
  func `Control less picture in picture window floats`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: false,
        forceTiling: false
      ) == .floating)
  }

  @Test(arguments: [
    (kAXWindowRole, Optional("AXSystemDialog")),
    (kAXWindowRole, Optional("AXFloatingWindow")),
    (kAXSheetRole, nil),
  ])
  func `System dialogs and sheets float by default`(
    testCase: (role: String, subrole: String?)
  ) {
    #expect(
      classifyWindow(
        role: testCase.role,
        subrole: testCase.subrole,
        appID: "com.example.app",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: false,
        forceTiling: false
      ) == .floating)
  }

  @Test
  func `Modal standard window floats even when resizable`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "com.example.app",
        hasCloseButton: true,
        canResize: true,
        isModal: true,
        configuredFloating: false,
        forceTiling: false
      ) == .floating)
  }

  @Test
  func `Quick look service window floats even when standard`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        appID: "com.apple.quicklook.QuickLookUIService",
        hasCloseButton: true,
        canResize: true,
        configuredFloating: false,
        forceTiling: false
      ) == .floating)
  }

  @Test
  func `Configured floating tracks unknown auxiliary window`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXUnknownSubrole,
        appID: "com.example.app",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: true,
        forceTiling: false
      ) == .floating)
  }

  @Test
  func `Transient close button failure preserves managed window`() {
    #expect(
      shouldTreatWindowAsClosable(
        error: .cannotComplete,
        hasValue: false,
        wasPreviouslyManaged: true
      ))
    #expect(
      shouldTreatWindowAsClosable(
        error: .cannotComplete,
        hasValue: false,
        wasPreviouslyManaged: false
      ) == false)
  }

  @Test(
    arguments: [
      (AXError.cannotComplete, AXError.success),
      (AXError.success, AXError.cannotComplete),
    ],
    [
      (Optional<WindowDisposition>.none, WindowDisposition.unavailable),
      (WindowDisposition.tiled, .tiled),
      (WindowDisposition.floating, .floating),
    ])
  func `Transient metadata failure preserves previous disposition`(
    errors: (closeButton: AXError, sizeSettable: AXError),
    dispositions: (previous: WindowDisposition?, expected: WindowDisposition)
  ) {
    #expect(
      fallbackDispositionForTransientWindowMetadata(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        closeButtonError: errors.closeButton,
        sizeSettableError: errors.sizeSettable,
        previousDisposition: dispositions.previous
      ) == dispositions.expected)
  }

  @Test
  func `Successful metadata does not need a fallback disposition`() {
    #expect(
      fallbackDispositionForTransientWindowMetadata(
        role: kAXWindowRole,
        subrole: kAXStandardWindowSubrole,
        closeButtonError: .success,
        sizeSettableError: .success,
        previousDisposition: .floating
      ) == nil)
  }

  @Test
  func `Unsupported size attribute means fixed size`() {
    #expect(
      windowCanResize(
        sizeSettableError: .attributeUnsupported,
        isSettable: false
      ) == false)
    #expect(
      windowCanResize(
        sizeSettableError: .cannotComplete,
        isSettable: false
      ))
  }

  @Test
  func `Transient modal read preserves cached value`() {
    #expect(
      resolvedWindowModalState(
        error: .cannotComplete,
        observedValue: nil,
        cachedValue: true
      ) == true)
    #expect(
      resolvedWindowModalState(
        error: .cannotComplete,
        observedValue: nil,
        cachedValue: nil
      ) == nil)
    #expect(
      resolvedWindowModalState(
        error: .attributeUnsupported,
        observedValue: nil,
        cachedValue: true
      ) == false)
  }

  @Test
  func `Missing close button remains unmanaged`() {
    #expect(
      shouldTreatWindowAsClosable(
        error: .noValue,
        hasValue: false,
        wasPreviouslyManaged: true
      ) == false)
  }

  @Test
  func `Force tiling overrides window shape filter`() {
    #expect(
      classifyWindow(
        role: kAXWindowRole,
        subrole: kAXUnknownSubrole,
        appID: "net.imput.helium",
        hasCloseButton: false,
        canResize: false,
        configuredFloating: false,
        forceTiling: true
      ) == .tiled)
  }

  @Test
  func `Application activation selects target with unmanaged auxiliary windows`() {
    #expect(
      shouldSelectSpecificWindow(
        activatesApplication: true,
        hasUnmanagedAuxiliaryWindows: true,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      ))
  }

  @Test
  func `Stable single window focus keeps fast path`() {
    #expect(
      shouldSelectSpecificWindow(
        activatesApplication: true,
        hasUnmanagedAuxiliaryWindows: false,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      ) == false)
  }

  @Test
  func `Frontmost single window defers selection to async validation`() {
    #expect(
      shouldSelectSpecificWindow(
        activatesApplication: false,
        hasUnmanagedAuxiliaryWindows: true,
        hasMultipleManagedWindows: false,
        focusWritePending: false,
        targetWasLastFocused: true
      ) == false)
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

  @Test func vanishedWindowRetryIdentityIsRemoved() {
    let processID: pid_t = 42
    let vanished = AXWindowElementIdentity(
      processID: processID,
      element: AXUIElementCreateApplication(processID)
    )
    let live = AXWindowElementIdentity(
      processID: processID,
      element: AXUIElementCreateSystemWide()
    )

    let failures = [vanished: 2, live: 1].filter { [live].contains($0.key) }

    #expect(failures[vanished] == nil)
    #expect(failures[live] == 1)
  }

  @Test func repeatedBatchFailuresDisableBatchedAttributeReads() {
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 1) == false)
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 2) == false)
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
