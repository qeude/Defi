import DefiRuntime
import ApplicationServices
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowDiscoveryTests {
  private let processID: pid_t = 42
  private let frame = Rect(x: 4, y: 34, width: 2_554, height: 1_354)

  @Test
  func axFrameConversionValidatesValueTypes() throws {
    var point = CGPoint(x: 4, y: 34)
    var size = CGSize(width: 800, height: 700)
    let positionValue = try #require(AXValueCreate(.cgPoint, &point))
    let sizeValue = try #require(AXValueCreate(.cgSize, &size))
    #expect(frameFromAXValues(positionValue: positionValue, sizeValue: sizeValue)
      == Rect(x: 4, y: 34, width: 800, height: 700))
    #expect(frameFromAXValues(positionValue: nil, sizeValue: sizeValue) == nil)
    #expect(frameFromAXValues(positionValue: "invalid" as CFString, sizeValue: sizeValue) == nil)
    #expect(frameFromAXValues(positionValue: sizeValue, sizeValue: positionValue) == nil)
  }

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

  @Test(
    arguments: [
      (pid_t?(42), pid_t?(7), pid_t?(nil), pid_t?(nil)),
      (7, 42, 42, 42),
      (42, nil, nil, 42),
      (42, 42, nil, 42),
    ] as [(pid_t?, pid_t?, pid_t?, pid_t?)]
  )
  func `Focused process resolves only from agreeing or verified sources`(
    accessibilityProcessID: pid_t?,
    frontmostProcessID: pid_t?,
    verifiedNativeFocusProcessID: pid_t?,
    expected: pid_t?
  ) {
    #expect(
      consistentFocusedProcessID(
        accessibilityProcessID: accessibilityProcessID,
        frontmostProcessID: frontmostProcessID,
        verifiedNativeFocusProcessID: verifiedNativeFocusProcessID
      ) == expected)
  }

  @NavigationActor
  @Test
  func `Pending native focus reuses the stable window only for an unknown or verified process`() {
    let platform = MacOSPlatform()
    let window = Window(id: WindowID(rawValue: 1), appID: "com.example.app", title: "Main", frame: frame,
      processID: processID, monitorID: MonitorID(rawValue: 1))
    platform.lastFocusedWindowByProcess[processID] = window.id
    #expect(platform.stableWindowID(processID: processID, in: [window]) == window.id)
    platform.nativeFocusEventPending = true
    #expect(platform.stableWindowID(processID: processID, in: [window]) == nil)
    platform.nativeFocusEventHasUnknownProcess = true
    #expect(platform.stableWindowID(processID: processID, in: [window]) == window.id)
    platform.nativeFocusEventHasUnknownProcess = false
    platform.nativeFocusEventProcessIDs = [99]
    #expect(platform.stableWindowID(processID: processID, in: [window]) == nil)
    platform.lastFocusedWindowByProcess = [:]
    platform.nativeFocusEventProcessIDs = [processID]
    #expect(platform.stableWindowID(processID: processID, in: [window]) == window.id,
      "A verified process accepts its single window")
  }

  @Test
  func `Focused frame matches a managed window through small drift but not a distant auxiliary window`() {
    let managed = Window(id: WindowID(rawValue: 1), appID: "com.example.app", title: "Main", frame: frame,
      processID: processID, monitorID: MonitorID(rawValue: 1))
    #expect(focusedWindowIDMatchingFrame(processID: processID,
      focusedFrame: Rect(x: 400, y: 300, width: 500, height: 300), windows: [managed]) == nil)
    #expect(focusedWindowIDMatchingFrame(processID: processID,
      focusedFrame: Rect(x: frame.x + 2, y: frame.y, width: frame.width, height: frame.height),
      windows: [managed]) == managed.id)
  }

  @Test
  func `Window matching prefers the exact frame, breaks ties by title, and rejects unrelated surfaces`() {
    func record(_ id: CGWindowID, _ title: String, _ frame: Rect) -> CGWindowRecord {
      CGWindowRecord(id: id, processID: processID, layer: 0, title: title, frame: frame)
    }
    func match(_ title: String, _ records: [CGWindowRecord]) -> CGWindowID? {
      bestCGWindow(processID: processID, title: title, frame: frame, records: records)?.id
    }
    #expect(match("WhatsApp - Helium", [record(2, "", Rect(x: 0, y: 0, width: 2_560, height: 30)),
      record(1, "WhatsApp 🔊", frame)]) == 1)
    #expect(match("Window", [record(1, "Other", frame), record(2, "Window", frame)]) == 2)
    #expect(match("Picture in Picture", [record(1, "", Rect(x: 104, y: 34, width: 2_554, height: 1_354))]) == nil)
  }

  @Test
  func `An exact window identifier is needed for identical windows or a stale preferred identity`() {
    let stale = CGWindowRecord(id: 56, processID: processID, layer: 0, title: "",
      frame: Rect(x: 3_000, y: 37, width: 1_200, height: 800))
    let current = CGWindowRecord(id: 19609, processID: processID, layer: 0, title: "", frame: frame)
    #expect(cgWindowDiscoveryNeedsExactID(preferredWindowID: WindowID(rawValue: 56), processID: processID,
      title: "Window", frame: frame, records: [stale, current], excluding: []))
    #expect(!cgWindowDiscoveryNeedsExactID(preferredWindowID: WindowID(rawValue: 19609), processID: processID,
      title: "Window", frame: frame, records: [stale, current], excluding: []))
    let identical = [1, 2].map {
      CGWindowRecord(id: CGWindowID($0), processID: processID, layer: 0, title: "Defi", frame: frame)
    }
    #expect(cgWindowDiscoveryNeedsExactID(processID: processID, title: "Defi", frame: frame, records: identical,
      excluding: []))
    #expect(!cgWindowDiscoveryNeedsExactID(processID: processID, title: "Defi", frame: frame,
      records: [identical[0]], excluding: []))
  }

  struct FocusRecoveryCase: CustomTestStringConvertible, Sendable {
    let name: String
    let target: (Rect, String)
    let candidates: [(Rect, String)]
    let expectedIndex: Int?

    var testDescription: String { name }
  }

  static let focusRecoveryCases: [FocusRecoveryCase] = {
    let mainFrame = Rect(x: 4, y: 34, width: 2_554, height: 1_354)
    let auxiliaryFrame = Rect(x: 400, y: 300, width: 500, height: 300)
    return [
      FocusRecoveryCase(
        name: "matches unmanaged auxiliary window by frame",
        target: (auxiliaryFrame, "Preferences"),
        candidates: [(mainFrame, "Main"), (auxiliaryFrame, "Preferences")],
        expectedIndex: 1
      ),
      FocusRecoveryCase(
        name: "searches beyond first 32 candidates",
        target: (auxiliaryFrame, "Preferences"),
        candidates: Array(
          repeating: (Rect(x: 0, y: 0, width: 100, height: 100), "Other"),
          count: 32
        ) + [(auxiliaryFrame, "Preferences")],
        expectedIndex: 32
      ),
      FocusRecoveryCase(
        name: "rejects distant accessibility window",
        target: (auxiliaryFrame, "Preferences"),
        candidates: [(mainFrame, "Main")],
        expectedIndex: nil
      ),
      FocusRecoveryCase(
        name: "uses title to break geometry tie",
        target: (auxiliaryFrame, "Preferences"),
        candidates: [(auxiliaryFrame, "Main"), (auxiliaryFrame, "Preferences")],
        expectedIndex: 1
      ),
    ]
  }()

  @Test(arguments: focusRecoveryCases)
  func `Focus recovery selects the closest accessibility window`(_ scenario: FocusRecoveryCase) {
    #expect(
      closestFocusRecoveryWindowIndex(
        target: scenario.target,
        candidates: scenario.candidates
      ) == scenario.expectedIndex)
  }

  @Test
  func `Discovery binds the AX or preferred window ID only to a live record of the same process`() {
    func record(_ id: CGWindowID, _ title: String, process: pid_t = 42, frame: Rect? = nil) -> CGWindowRecord {
      CGWindowRecord(id: id, processID: process, layer: 0, title: title, frame: frame ?? self.frame)
    }
    func resolve(ax: UInt32? = nil, preferred: UInt64?, title: String = "Window", _ records: [CGWindowRecord],
      excluding: Set<CGWindowID> = []) -> CGWindowID? {
      cgWindowRecordForDiscovery(axWindowID: ax, preferredWindowID: preferred.map(WindowID.init(rawValue:)),
        processID: processID, title: title, frame: frame, records: records, excluding: excluding)?.id
    }
    #expect(resolve(preferred: 42, [record(42, "Window")]) == 42)
    #expect(resolve(preferred: 42, []) == nil)
    #expect(resolve(preferred: 42, [record(42, "Other", process: 7)]) == nil, "recycled by another process")
    #expect(resolve(preferred: 42, [record(42, "Window")], excluding: [42]) == nil)
    let refreshed = [record(43, "Refreshed"), record(44, "Sibling")]
    #expect(resolve(ax: 44, preferred: 43, title: "Sibling", refreshed, excluding: [43]) == 44)
    #expect(resolve(preferred: 43, title: "Sibling", refreshed, excluding: [43]) == nil)
    #expect(resolve(ax: 42, preferred: nil, [record(42, "", frame: Rect(x: 0, y: 940, width: 500, height: 500))]) == 42,
      "the AX window ID bypasses redacted geometry")
    #expect(resolve(preferred: 42, [record(43, "Window")]) == nil, "a missing preferred record does not rematch")
    #expect(resolve(preferred: nil, [record(43, "Window")]) == 43)
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

  // role, subrole, app, close button, resizable, modal, configured floating, force tiling -> disposition
  @Test(arguments: [
    (kAXWindowRole, kAXStandardWindowSubrole, "net.imput.helium", true, true, false, false, false, .tiled),
    // a control-less picture in picture window
    (kAXWindowRole, kAXStandardWindowSubrole, "net.imput.helium", false, false, false, false, false, .floating),
    // app-drawn popups stay unmanaged unless modal
    (kAXWindowRole, "AXSystemDialog", "com.example.app", false, false, false, false, false, .ignored),
    (kAXWindowRole, "AXSystemDialog", "com.example.app", false, false, true, false, false, .floating),
    (kAXWindowRole, "AXSystemFloatingWindow", "com.example.app", false, false, false, false, false, .ignored),
    (kAXWindowRole, "AXSystemFloatingWindow", "com.example.app", false, false, true, false, false, .floating),
    (kAXWindowRole, "AXDialog", "com.example.app", false, false, false, false, false, .floating),
    (kAXWindowRole, "AXFloatingWindow", "com.example.app", false, false, false, false, false, .floating),
    (kAXSheetRole, nil, "com.example.app", false, false, false, false, false, .floating),
    (kAXWindowRole, kAXStandardWindowSubrole, "com.example.app", true, true, true, false, false, .floating),
    // only Apple's Quick Look service bundle floats, in any case
    (kAXWindowRole, kAXStandardWindowSubrole, "com.apple.quicklook.QuickLookUIService", true, true, false, false, false,
      .floating),
    (kAXWindowRole, kAXStandardWindowSubrole, "COM.APPLE.QUICKLOOK.QUICKLOOKUISERVICE", true, true, false, false, false,
      .floating),
    (kAXWindowRole, kAXStandardWindowSubrole, "com.example.quicklook.editor", true, true, false, false, false, .tiled),
    (kAXWindowRole, kAXUnknownSubrole, "com.example.app", false, false, false, true, false, .floating),
    (kAXWindowRole, kAXUnknownSubrole, "net.imput.helium", false, false, false, false, true, .tiled),
  ] as [(String, String?, String, Bool, Bool, Bool, Bool, Bool, WindowDisposition)])
  func `Window classification follows role, controls, and rules`(role: String, subrole: String?, appID: String,
    hasCloseButton: Bool, canResize: Bool, isModal: Bool, configuredFloating: Bool, forceTiling: Bool,
    disposition: WindowDisposition) {
    #expect(classifyWindow(role: role, subrole: subrole, appID: appID, hasCloseButton: hasCloseButton,
      canResize: canResize, isModal: isModal, configuredFloating: configuredFloating, forceTiling: forceTiling)
      == disposition)
  }

  @Test
  func `Only a transient close button failure keeps a managed window closable`() {
    #expect(shouldTreatWindowAsClosable(error: .cannotComplete, hasValue: false, wasPreviouslyManaged: true))
    #expect(!shouldTreatWindowAsClosable(error: .cannotComplete, hasValue: false, wasPreviouslyManaged: false))
    #expect(!shouldTreatWindowAsClosable(error: .noValue, hasValue: false, wasPreviouslyManaged: true))
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

  @Test(arguments: [(true, true, true), (true, false, false), (false, true, false)])
  func `Activation selects a specific window only past unmanaged auxiliary windows`(activates: Bool,
    hasAuxiliary: Bool, selects: Bool) {
    #expect(shouldSelectSpecificWindow(activatesApplication: activates, hasUnmanagedAuxiliaryWindows: hasAuxiliary,
      hasMultipleManagedWindows: false, focusWritePending: false, targetWasLastFocused: true) == selects)
  }

}

struct WindowClassificationReviewFeedbackTests {
  @Test func repeatedBatchFailuresDisableBatchedAttributeReads() {
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 1) == false)
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 2) == false)
    #expect(shouldDisableBatchedWindowAttributeReads(failureCount: 3))
  }

}

struct NativeWindowTabDiscoveryTests {
  private let processID: pid_t = 42
  private let frame = Rect(x: 100, y: 40, width: 1_200, height: 900)

  @Test
  func `Previously managed AX windows claim their CG identity first`() {
    let existing = WindowID(rawValue: 42)
    let previousWindowIDs: [WindowID?] = [nil, existing, nil, existing]

    let order = previousWindowIDs.indices.sorted { lhs, rhs in
      windowDiscoveryCandidateComesFirst(
        lhsPreviousWindowID: previousWindowIDs[lhs],
        lhsIndex: lhs,
        rhsPreviousWindowID: previousWindowIDs[rhs],
        rhsIndex: rhs
      )
    }

    #expect(order == [1, 3, 0, 2])
  }

  struct TabMembershipCase: CustomTestStringConvertible, Sendable {
    let name: String
    let representativeTitle: String
    // Windows after the representative (id 1).
    let windows: [Window]
    let group: NativeWindowTabGroup
    var retained: Set<UInt64> = []
    var observed: Set<UInt64> = []
    let backing: Set<UInt64>

    var testDescription: String { name }
  }

  static func tab(_ id: UInt64, _ title: String, x: Double = 100, width: Double = 1_200,
    height: Double = 900) -> Window {
    Window(id: WindowID(rawValue: id), appID: "com.mitchellh.ghostty", title: title,
      frame: Rect(x: x, y: 40, width: width, height: height), role: kAXWindowRole,
      subrole: kAXStandardWindowSubrole, processID: 42, monitorID: MonitorID(rawValue: 1))
  }

  static func ids(_ raw: Set<UInt64>) -> Set<WindowID> { Set(raw.map(WindowID.init(rawValue:))) }

  static let tabMembershipCases = [
    TabMembershipCase(name: "backing windows within a few points collapse behind the representative",
      representativeTitle: "Defi",
      windows: [tab(2, "Defi", width: 1_202, height: 899), tab(3, "Defi", width: 1_202), tab(4, "Other"),
        tab(2, "Defi", width: 1_202, height: 899)],
      group: NativeWindowTabGroup(tabTitles: ["Defi", "Defi"]), backing: [2, 3]),
    TabMembershipCase(name: "ambiguous membership leaves windows untouched", representativeTitle: "Defi",
      windows: [tab(2, "Defi"), tab(3, "Defi"), tab(4, "Defi")],
      group: NativeWindowTabGroup(tabTitles: ["Defi", "Defi"]), backing: []),
    TabMembershipCase(name: "known members survive temporary frame divergence", representativeTitle: "Defi",
      windows: [tab(2, "Defi", x: 2_000), tab(3, "Defi", x: -2_000)],
      group: NativeWindowTabGroup(tabTitles: ["Defi", "Defi"], backingWindowIDs: ids([2, 3])), backing: [2, 3]),
    TabMembershipCase(name: "a known direct backing stays coalesced when rediscovered", representativeTitle: "Defi",
      windows: [tab(2, "Defi")],
      group: NativeWindowTabGroup(tabTitles: ["Defi", "Defi"], selectedTabTitle: "Defi", backingWindowIDs: ids([2])),
      backing: [2]),
    TabMembershipCase(name: "unique titles recover membership after a visible restart", representativeTitle: "Selected",
      windows: [tab(2, "First", x: 2_000), tab(3, "Second", x: -2_000)],
      group: NativeWindowTabGroup(tabTitles: ["First", "Second"]), backing: [2, 3]),
    TabMembershipCase(name: "a growing group absorbs its newly observed backing window", representativeTitle: "Third",
      windows: [tab(2, "First"), tab(3, "Second")],
      group: NativeWindowTabGroup(tabTitles: ["First", "Second", "Third"], selectedTabTitle: "Third",
        backingWindowIDs: ids([2])), retained: [2], observed: [3], backing: [2, 3]),
    TabMembershipCase(name: "the selected AppKit tab absorbs the retained previous window", representativeTitle: "Recents",
      windows: [tab(2, "Desktop", x: -2_000)],
      group: NativeWindowTabGroup(tabTitles: ["Desktop", "Recents"], selectedTabTitle: "Recents"), retained: [2],
      backing: [2]),
  ]

  @Test(arguments: tabMembershipCases)
  func `Native tab membership coalesces only unambiguous backing windows`(_ scenario: TabMembershipCase) {
    let representative = WindowID(rawValue: 1)
    let backing = nativeTabBackingWindowIDsByRepresentative(
      windows: [Self.tab(1, scenario.representativeTitle)] + scenario.windows,
      groupsByRepresentativeID: [representative: scenario.group], retainedWindowIDs: Self.ids(scenario.retained),
      additionalBackingWindowIDsByRepresentative: scenario.observed.isEmpty ? [:]
        : [representative: Self.ids(scenario.observed)])
    #expect(backing[representative] ?? [] == Self.ids(scenario.backing))
  }

  @Test
  func `A native tab representative swap keeps logical identity unless ambiguous`() {
    let old = WindowID(rawValue: 1), first = WindowID(rawValue: 2), second = WindowID(rawValue: 3)
    func rebound(_ group: NativeWindowTabGroup, representative: WindowID, previous: NativeWindowTabGroup)
      -> Set<WindowID> {
      nativeWindowTabGroupRebindingKnownMembers(group, representativeID: representative, processID: processID,
        previousGroupsByRepresentativeID: [old: previous], previousProcessIDs: [old: processID]).backingWindowIDs
    }
    let known = NativeWindowTabGroup(tabTitles: ["First", "Second"], backingWindowIDs: [first, second])
    #expect(rebound(NativeWindowTabGroup(tabTitles: ["First", "Second"]), representative: first, previous: known)
      == [old, second])
    #expect(rebound(NativeWindowTabGroup(tabTitles: ["First", "Second"], selectedTabTitle: "First"),
      representative: first, previous: NativeWindowTabGroup(tabTitles: ["First", "Second"], selectedTabTitle: "Second",
        backingWindowIDs: [first])) == [old])
    #expect(rebound(NativeWindowTabGroup(tabTitles: ["First", "Second", "Third"]), representative: old,
      previous: known) == [first, second])
    #expect(nativeWindowTabRepresentativeReplacements(previousWindowIDs: [old], nextWindowIDs: [first],
      groupsByRepresentativeID: [first: NativeWindowTabGroup(tabTitles: ["First", "Second"], backingWindowIDs: [old])])
      == [old: first])
    #expect(nativeWindowTabRepresentativeReplacements(previousWindowIDs: [old, first], nextWindowIDs: [second],
      groupsByRepresentativeID: [second: NativeWindowTabGroup(tabTitles: ["First", "Second", "Third"],
        backingWindowIDs: [old, first])]).isEmpty, "An ambiguous replacement keeps every logical identity")
  }

  @Test
  func `Only a title bar tab group is treated as native window tabs`() {
    #expect(
      nativeTabGroupFrameIsInWindowChrome(
        Rect(x: 100, y: 72, width: 1_200, height: 28),
        windowFrame: frame
      )
    )
    #expect(
      nativeTabGroupFrameIsInWindowChrome(
        Rect(x: 243, y: 92, width: 1_057, height: 28),
        windowFrame: frame
      )
    )
    #expect(
      nativeTabGroupFrameIsInWindowChrome(
        Rect(x: 140, y: 240, width: 600, height: 40),
        windowFrame: frame
      ) == false
    )
  }
}
