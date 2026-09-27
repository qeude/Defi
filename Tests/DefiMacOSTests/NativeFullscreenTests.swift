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

  @Test(arguments: [1, 2])
  func `Physical screen coverage detects tracked observations`(observationCount: Int) {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.physicalFrame)

    #expect(
      nativeFullscreenWindowIDs(
        windows: Array(repeating: window, count: observationCount),
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ) == [window.id]
    )
  }

  @Test
  func `Late native fullscreen observation is recognized after the transition`() {
    let windowID = WindowID(rawValue: 1)
    let beforeEntry = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let afterEntry = makeWindow(id: 1, processID: 10, frame: monitor.physicalFrame)
    let fullscreenSurface = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "Fullscreen",
      frame: monitor.physicalFrame
    )

    #expect(
      nativeFullscreenWindowIDs(
        windows: [beforeEntry],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: windowID]
      ).isEmpty
    )
    #expect(
      nativeFullscreenWindowIDs(
        windows: [beforeEntry],
        cgWindows: [fullscreenSurface],
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: windowID]
      ) == [windowID]
    )
    #expect(
      nativeFullscreenWindowIDs(
        windows: [afterEntry],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: windowID]
      ) == [windowID]
    )
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

  @Test
  func `Visible frame and picture in picture are not fullscreen`() {
    let tiled = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let pictureInPicture = makeWindow(
      id: 2,
      processID: 20,
      frame: Rect(x: 900, y: 500, width: 400, height: 300),
      floating: true
    )

    #expect(
      nativeFullscreenWindowIDs(
        windows: [tiled, pictureInPicture],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ).isEmpty
    )
  }

  @Test
  func `Maximized surface without its missing top band is not fullscreen`() {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let surface = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "",
      frame: monitor.frame
    )

    #expect(
      nativeFullscreenWindowIDs(
        windows: [window],
        cgWindows: [surface],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ).isEmpty
    )
  }

  @Test
  func `Adjacent process surfaces can cover the physical screen`() {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let surfaces = [
      CGWindowRecord(
        id: 99,
        processID: 10,
        layer: 0,
        title: "",
        frame: Rect(x: 0, y: 33, width: 1_512, height: 949)
      ),
      CGWindowRecord(
        id: 100,
        processID: 10,
        layer: 0,
        title: "",
        frame: Rect(x: 0, y: 0, width: 1_512, height: 33)
      ),
    ]

    #expect(
      nativeFullscreenWindowIDs(
        windows: [window],
        cgWindows: surfaces,
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ) == [window.id]
    )
  }

  @Test
  func `Stale offscreen fullscreen surfaces do not hide visible parent`() {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let surfaces = [
      CGWindowRecord(
        id: 99,
        processID: 10,
        layer: 0,
        title: "",
        frame: Rect(x: 0, y: 33, width: 1_512, height: 949),
        isOnscreen: false
      ),
      CGWindowRecord(
        id: 100,
        processID: 10,
        layer: 0,
        title: "",
        frame: Rect(x: 0, y: 0, width: 1_512, height: 33),
        isOnscreen: false
      ),
      CGWindowRecord(
        id: 1,
        processID: 10,
        layer: 0,
        title: "Window 1",
        frame: monitor.frame,
        isOnscreen: true
      ),
    ]

    #expect(
      nativeFullscreenWindowIDs(
        windows: [window],
        cgWindows: surfaces,
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: window.id]
      ).isEmpty
    )
  }

  @Test
  func `Fullscreen helper selects last focused window from its process`() {
    let first = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let second = makeWindow(id: 2, processID: 10, frame: monitor.frame)
    let helper = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "",
      frame: monitor.physicalFrame
    )

    #expect(
      nativeFullscreenWindowIDs(
        windows: [first, second],
        cgWindows: [helper],
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: second.id]
      ) == [second.id]
    )
  }

  @Test
  func `Exact fullscreen surface wins over stale process focus`() {
    let processID: Int32 = 10
    let staleFocused = makeWindow(
      id: 1,
      processID: processID,
      frame: monitor.frame
    )
    let fullscreen = makeWindow(
      id: 2,
      processID: processID,
      frame: monitor.physicalFrame
    )
    let fullscreenSurface = CGWindowRecord(
      id: 2,
      processID: processID,
      layer: 0,
      title: "Video",
      frame: monitor.physicalFrame
    )
    let detected = nativeFullscreenWindowIDs(
      windows: [staleFocused, fullscreen],
      cgWindows: [fullscreenSurface],
      monitors: [monitor],
      lastFocusedWindowByProcess: [processID: staleFocused.id]
    )

    #expect(detected == [fullscreen.id])
    #expect(
      retainedNativeFullscreenProcessIDsByWindowID(
        detectedWindowIDs: detected,
        previous: [staleFocused.id: processID],
        observedProcessIDs: [
          staleFocused.id: processID,
          fullscreen.id: processID,
        ],
        fullscreenProcessIDs: [processID],
        explicitlyRemovedWindowIDs: []
      ) == [fullscreen.id: processID]
    )
  }

  @Test
  func `Remapped fullscreen surface keeps previous logical window identity`() {
    let surfaceWindow = makeWindow(
      id: 99,
      processID: 10,
      frame: monitor.physicalFrame
    )
    let logicalWindowID = WindowID(rawValue: 1)

    #expect(
      nativeFullscreenWindowIDs(
        windows: [surfaceWindow],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [10: logicalWindowID]
      ) == [logicalWindowID]
    )
  }

  @Test
  func `Ambiguous fullscreen helper does not guess`() {
    let first = makeWindow(id: 1, processID: 10, frame: monitor.frame)
    let second = makeWindow(id: 2, processID: 10, frame: monitor.frame)
    let helper = CGWindowRecord(
      id: 99,
      processID: 10,
      layer: 0,
      title: "",
      frame: monitor.physicalFrame
    )

    #expect(
      nativeFullscreenWindowIDs(
        windows: [first, second],
        cgWindows: [helper],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ).isEmpty
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
  func `Inactive space retains fullscreen identity while process still covers display`() {
    let windowID = WindowID(rawValue: 1)
    let processID: Int32 = 10

    let retained = retainedNativeFullscreenProcessIDsByWindowID(
      detectedWindowIDs: [],
      previous: [windowID: processID],
      observedProcessIDs: [:],
      fullscreenProcessIDs: [processID],
      explicitlyRemovedWindowIDs: []
    )
    #expect(retained == [windowID: processID])
    #expect(
      retainedNativeFullscreenProcessIDsByWindowID(
        detectedWindowIDs: [],
        previous: retained,
        observedProcessIDs: [:],
        fullscreenProcessIDs: [],
        explicitlyRemovedWindowIDs: []
      ).isEmpty
    )
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
