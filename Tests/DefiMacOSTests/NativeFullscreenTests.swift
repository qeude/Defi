import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

@testable import DefiMacOS

struct NativeFullscreenTests {
  private let monitor = MonitorSnapshot(
    id: MonitorID(rawValue: 1),
    frame: Rect(x: 0, y: 23, width: 1_512, height: 959),
    physicalFrame: Rect(x: 0, y: 0, width: 1_512, height: 982)
  )

  struct DetectionCase: CustomTestStringConvertible, Sendable {
    let name: String
    let windows: [Window]
    var surfaces: [CGWindowRecord] = []
    var lastFocused: [Int32: WindowID] = [:]
    let fullscreen: Set<WindowID>

    var testDescription: String { name }
  }

  static let visible = Rect(x: 0, y: 23, width: 1_512, height: 959)
  static let physical = Rect(x: 0, y: 0, width: 1_512, height: 982)

  static func window(_ id: UInt64, _ frame: Rect, floating: Bool = false) -> Window {
    Window(id: WindowID(rawValue: id), appID: "app", title: "Window \(id)", frame: frame, processID: 10,
      floating: floating)
  }

  static func surface(_ id: CGWindowID, _ frame: Rect, title: String = "", onscreen: Bool = true) -> CGWindowRecord {
    CGWindowRecord(id: id, processID: 10, layer: 0, title: title, frame: frame, isOnscreen: onscreen)
  }

  static let menuBand = Rect(x: 0, y: 0, width: 1_512, height: 33)
  static let belowBand = Rect(x: 0, y: 33, width: 1_512, height: 949)
  static let detectionCases = [
    DetectionCase(name: "a window covering the physical screen", windows: [window(1, physical)],
      fullscreen: [WindowID(rawValue: 1)]),
    DetectionCase(name: "duplicate observations of one window", windows: [window(1, physical), window(1, physical)],
      fullscreen: [WindowID(rawValue: 1)]),
    DetectionCase(name: "a visible-frame window alone", windows: [window(1, visible)],
      lastFocused: [10: WindowID(rawValue: 1)], fullscreen: []),
    DetectionCase(name: "a late fullscreen surface for the focused window", windows: [window(1, visible)],
      surfaces: [surface(99, physical)], lastFocused: [10: WindowID(rawValue: 1)], fullscreen: [WindowID(rawValue: 1)]),
    DetectionCase(name: "a visible frame and picture in picture",
      windows: [window(1, visible), window(2, Rect(x: 900, y: 500, width: 400, height: 300), floating: true)],
      fullscreen: []),
    DetectionCase(name: "a maximized surface without the menu band", windows: [window(1, visible)],
      surfaces: [surface(99, visible)], fullscreen: []),
    DetectionCase(name: "adjacent surfaces covering the screen", windows: [window(1, visible)],
      surfaces: [surface(99, belowBand), surface(100, menuBand)], fullscreen: [WindowID(rawValue: 1)]),
    DetectionCase(name: "stale offscreen surfaces behind a visible parent", windows: [window(1, visible)],
      surfaces: [surface(99, belowBand, onscreen: false), surface(100, menuBand, onscreen: false),
        surface(1, visible, title: "Window 1")], lastFocused: [10: WindowID(rawValue: 1)], fullscreen: []),
    DetectionCase(name: "a helper surface picks the process's last focused window",
      windows: [window(1, visible), window(2, visible)], surfaces: [surface(99, physical)],
      lastFocused: [10: WindowID(rawValue: 2)], fullscreen: [WindowID(rawValue: 2)]),
    DetectionCase(name: "an ambiguous helper surface does not guess", windows: [window(1, visible), window(2, visible)],
      surfaces: [surface(99, physical)], fullscreen: []),
    DetectionCase(name: "an exact surface wins over stale process focus",
      windows: [window(1, visible), window(2, physical)], surfaces: [surface(2, physical)],
      lastFocused: [10: WindowID(rawValue: 1)], fullscreen: [WindowID(rawValue: 2)]),
    DetectionCase(name: "a remapped surface keeps the logical window identity", windows: [window(99, physical)],
      lastFocused: [10: WindowID(rawValue: 1)], fullscreen: [WindowID(rawValue: 1)]),
  ]

  @Test(arguments: detectionCases)
  func `Native fullscreen detection matches surfaces to the right window`(_ scenario: DetectionCase) {
    #expect(nativeFullscreenWindowIDs(windows: scenario.windows, cgWindows: scenario.surfaces, monitors: [monitor],
      lastFocusedWindowByProcess: scenario.lastFocused) == scenario.fullscreen)
  }

  @NavigationActor
  @Test
  func `Discovery grace bridges delayed fullscreen recognition`() throws {
    let config = Config()
    let fullscreenID = WindowID(rawValue: 2)
    let windows = (1...3).map {
      makeWindow(id: UInt64($0), processID: 10, frame: monitor.frame)
    }
    var state = RuntimeState(config: config)
    state.attachMonitor(monitor.id)
    for window in windows {
      try discoverWindow(window, decision: RuleDecision(), state: &state)
    }
    let originalColumnIndex = try #require(
      state.monitors[0].workspaces[0].columns.firstIndex {
        $0.windows.contains(fullscreenID)
      }
    )

    let missingIDs = Set([WindowID(rawValue: 1), WindowID(rawValue: 3)])
    let initialRetention = retainedWindowIDsWithinGracePeriod(
      missingIDs,
      previousDeadlines: [:],
      now: 10
    )
    let delayedRetention = retainedWindowIDsWithinGracePeriod(
      missingIDs,
      previousDeadlines: initialRetention.deadlines,
      now: 10.7
    )
    #expect(delayedRetention.windowIDs == missingIDs)

    let target = try #require(state.windows[fullscreenID])
    let delayedSnapshotWindows = windows.filter {
      $0.id == fullscreenID || delayedRetention.windowIDs.contains($0.id)
    }
    reconcileWindows(delayedSnapshotWindows, config: config, state: &state)
    let fullscreenSurface = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "Fullscreen",
      frame: monitor.physicalFrame
    )
    let detected = nativeFullscreenWindowIDs(
      windows: [target],
      cgWindows: [fullscreenSurface],
      monitors: [monitor],
      lastFocusedWindowByProcess: [10: fullscreenID]
    )
    reconcileWindows(
      [target],
      config: config,
      nativeFullscreenWindowIDs: detected,
      state: &state
    )
    let platform = MacOSPlatform()
    platform.targetFrames[fullscreenID] = target.frame
    platform.updateNativeFullscreenWindowIDs(detected)
    platform.apply([
      FrameAssignment(windowID: fullscreenID, frame: monitor.frame)
    ])

    #expect(detected == [fullscreenID])
    #expect(platform.targetFrames[fullscreenID] == target.frame)
    #expect(state.nativeFullscreenWindowIDs == [fullscreenID])
    #expect(
      state.nativeFullscreenTiledPlacements[fullscreenID]?.columnIndex
        == originalColumnIndex
    )
    #expect(
      Set(state.windows.keys) == Set([1, 2, 3].map { WindowID(rawValue: $0) })
    )
  }

  @Test(arguments: [true, false])
  func `Active fullscreen window requires an onscreen surface`(isOnscreen: Bool) {
    let windowID = WindowID(rawValue: 1)
    let surface = CGWindowRecord(
      id: 1,
      processID: 10,
      layer: 0,
      title: "Video",
      frame: Rect(x: 0, y: 33, width: 1_512, height: 949),
      isOnscreen: isOnscreen
    )
    let hiddenMenuBand = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "",
      frame: Rect(x: 0, y: 0, width: 1_512, height: 33),
      isOnscreen: false
    )

    #expect(
      activeNativeFullscreenWindowIDs(
        processIDsByWindowID: [windowID: 10],
        cgWindows: [surface, hiddenMenuBand],
        monitors: [monitor]
      ) == (isOnscreen ? [windowID] : [])
    )
  }

  @NavigationActor
  @Test
  func `Automatic focus write is skipped for fullscreen window`() {
    let windowID = WindowID(rawValue: 1)
    let platform = MacOSPlatform()
    platform.updateNativeFullscreenWindowIDs([windowID])
    var result: NativeFocusResult?

    let requestID = platform.focus(
      windowID,
      completion: { result = $0 }
    )

    #expect(requestID == nil)
    #expect(result == .completedWithoutMutation)
  }

  @NavigationActor
  @Test
  func `Frame application preserves fullscreen target`() {
    let windowID = WindowID(rawValue: 1)
    let original = Rect(x: 0, y: 0, width: 1_512, height: 982)
    let platform = MacOSPlatform()
    platform.targetFrames[windowID] = original
    platform.updateNativeFullscreenWindowIDs([windowID])

    platform.apply([
      FrameAssignment(
        windowID: windowID,
        frame: Rect(x: 100, y: 100, width: 600, height: 700)
      )
    ])

    #expect(platform.targetFrames[windowID] == original)
  }

  @NavigationActor
  @Test
  func `Fullscreen exit starts frame settlement`() {
    let windowID = WindowID(rawValue: 1)
    let platform = MacOSPlatform()
    platform.updateNativeFullscreenWindowIDs([windowID])
    #expect(platform.isInitialFrameSettlementActive(for: windowID))

    platform.updateNativeFullscreenWindowIDs([])

    #expect(platform.isInitialFrameSettlementActive(for: windowID))
  }

  @MainActor
  @Test
  func `Placeholder manager tracks only current fullscreen slots`() {
    let manager = NativeFullscreenPlaceholderManager()
    let windowID = WindowID(rawValue: 1)
    let siblingWindowID = WindowID(rawValue: 2)
    let otherMonitorWindowID = WindowID(rawValue: 3)
    let placeholders = [
      NativeFullscreenPlaceholder(
        windowID: windowID,
        monitorID: MonitorID(rawValue: 1),
        appID: "com.apple.TextEdit",
        title: "Document",
        frame: Rect(x: 100, y: 100, width: 600, height: 700)
      ),
      NativeFullscreenPlaceholder(
        windowID: siblingWindowID,
        monitorID: MonitorID(rawValue: 1),
        appID: "com.apple.TextEdit",
        title: "Sibling",
        frame: Rect(x: 800, y: 100, width: 600, height: 700)
      ),
      NativeFullscreenPlaceholder(
        windowID: otherMonitorWindowID,
        monitorID: MonitorID(rawValue: 2),
        appID: "com.apple.TextEdit",
        title: "Other monitor",
        frame: Rect(x: 1_600, y: 100, width: 600, height: 700)
      ),
    ]
    manager.sync(
      placeholders,
      selectedWindowID: windowID,
      stackingWindowID: nil,
      accentColor: 0xffc0_99ff
    )

    #expect(manager.visibleWindowIDs == Set(placeholders.map(\.windowID)))

    manager.sync(
      placeholders,
      selectedWindowID: windowID,
      stackingWindowID: nil,
      suppressedWindowIDs: [windowID],
      accentColor: 0xffc0_99ff
    )

    #expect(manager.visibleWindowIDs == [otherMonitorWindowID])

    manager.sync(
      [],
      selectedWindowID: nil,
      stackingWindowID: nil,
      accentColor: 0xffc0_99ff
    )

    #expect(manager.visibleWindowIDs.isEmpty)
  }

  @Test
  func `Active space change forces fresh topology`() {
    #expect(windowSnapshotInvalidation(for: .space, processID: nil) == .full)
    #expect(
      nativeFocusedWindowIDAfterEvent(
        .space,
        cachedWindowID: WindowID(rawValue: 1)
      ) == WindowID(rawValue: 1)
    )
  }

  @Test
  func `Fullscreen exit observation converges within the 750 ms grace`() {
    let windowID = WindowID(rawValue: 1)
    let entered = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [windowID],
      previousExitDeadlines: [:],
      explicitlyRemovedWindowIDs: [],
      now: 10
    )
    let transitionGap = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [],
      previousExitDeadlines: entered.exitDeadlines,
      explicitlyRemovedWindowIDs: [],
      now: 10.5
    )
    let exited = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [],
      previousExitDeadlines: transitionGap.exitDeadlines,
      explicitlyRemovedWindowIDs: [],
      now: 10.75
    )

    #expect(transitionGap.windowIDs == [windowID])
    #expect(entered.exitDeadlines[windowID] == 10.75)
    #expect(exited.windowIDs.isEmpty)
  }

  @Test
  func `Fullscreen exit ends once the window is back at its own size`() {
    let windowID = WindowID(rawValue: 1)
    let entered = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [windowID], previousExitDeadlines: [:], explicitlyRemovedWindowIDs: [], now: 10)
    let fullscreen = CGWindowRecord(id: 1, processID: 7, layer: 0, title: "",
      frame: Rect(x: 0, y: 0, width: 1512, height: 982), isOnscreen: true)
    let restored = CGWindowRecord(id: 1, processID: 7, layer: 0, title: "",
      frame: Rect(x: 762, y: 37, width: 746, height: 895), isOnscreen: true)
    let stillCovering = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [], previousExitDeadlines: entered.exitDeadlines, explicitlyRemovedWindowIDs: [],
      restoredWindowIDs: restoredNativeFullscreenWindowIDs(cgWindows: [fullscreen], monitors: [monitor]),
      now: 10.1)
    let back = stabilizedNativeFullscreenWindowIDs(
      detectedWindowIDs: [], previousExitDeadlines: entered.exitDeadlines, explicitlyRemovedWindowIDs: [],
      restoredWindowIDs: restoredNativeFullscreenWindowIDs(cgWindows: [restored], monitors: [monitor]),
      now: 10.1)

    #expect(stillCovering.windowIDs == [windowID])
    #expect(back.windowIDs.isEmpty)
  }

  @Test
  func `Fullscreen identity follows the detected window and survives an inactive space while the process covers the display`() {
    let stale = WindowID(rawValue: 1), fullscreen = WindowID(rawValue: 2)
    let processID: Int32 = 10
    #expect(retainedNativeFullscreenProcessIDsByWindowID(detectedWindowIDs: [fullscreen], previous: [stale: processID],
      observedProcessIDs: [stale: processID, fullscreen: processID], fullscreenProcessIDs: [processID],
      explicitlyRemovedWindowIDs: []) == [fullscreen: processID])
    let retained = retainedNativeFullscreenProcessIDsByWindowID(detectedWindowIDs: [], previous: [stale: processID],
      observedProcessIDs: [:], fullscreenProcessIDs: [processID], explicitlyRemovedWindowIDs: [])
    #expect(retained == [stale: processID])
    #expect(retainedNativeFullscreenProcessIDsByWindowID(detectedWindowIDs: [], previous: retained,
      observedProcessIDs: [:], fullscreenProcessIDs: [], explicitlyRemovedWindowIDs: []).isEmpty)
  }

  @Test
  func `Fullscreen space retains focus resources from masked spaces`() {
    let visibleID = WindowID(rawValue: 1)
    let maskedID = WindowID(rawValue: 2)
    let removedID = WindowID(rawValue: 3)

    #expect(
      fullscreenMaskedWindowIDs(
        previousWindowIDs: [visibleID, maskedID, removedID],
        nativeFullscreenWindowIDs: [visibleID],
        explicitlyRemovedWindowIDs: [removedID]
      ) == [visibleID, maskedID]
    )
    #expect(
      fullscreenMaskedWindowIDs(
        previousWindowIDs: [visibleID, maskedID],
        nativeFullscreenWindowIDs: [],
        explicitlyRemovedWindowIDs: []
      ).isEmpty
    )
  }

  private func makeWindow(
    id: UInt64,
    processID: Int32,
    frame: Rect,
    floating: Bool = false
  ) -> Window {
    Window(
      id: WindowID(rawValue: id),
      appID: "app",
      title: "Window \(id)",
      frame: frame,
      processID: processID,
      floating: floating
    )
  }
}
