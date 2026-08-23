import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

struct NativeFullscreenTests {
  private let monitor = MonitorSnapshot(
    id: MonitorID(rawValue: 1),
    frame: Rect(x: 0, y: 23, width: 1_512, height: 959),
    physicalFrame: Rect(x: 0, y: 0, width: 1_512, height: 982)
  )

  @Test
  func physicalScreenCoverageDetectsTrackedWindow() {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.physicalFrame)

    #expect(
      nativeFullscreenWindowIDs(
        windows: [window],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ) == [window.id]
    )
  }

  @Test
  func duplicateTrackedObservationsDoNotCrashDetection() {
    let window = makeWindow(id: 1, processID: 10, frame: monitor.physicalFrame)

    #expect(
      nativeFullscreenWindowIDs(
        windows: [window, window],
        cgWindows: [],
        monitors: [monitor],
        lastFocusedWindowByProcess: [:]
      ) == [window.id]
    )
  }

  @Test
  func visibleFrameAndPictureInPictureAreNotFullscreen() {
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
  func maximizedSurfaceWithoutItsMissingTopBandIsNotFullscreen() {
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
  func adjacentProcessSurfacesCanCoverThePhysicalScreen() {
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
  func staleOffscreenFullscreenSurfacesDoNotHideVisibleParent() {
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
  func fullscreenHelperSelectsLastFocusedWindowFromItsProcess() {
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
  func remappedFullscreenSurfaceKeepsPreviousLogicalWindowIdentity() {
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
  func ambiguousFullscreenHelperDoesNotGuess() {
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

  @Test
  func activeFullscreenWindowRequiresAnOnscreenSurface() {
    let windowID = WindowID(rawValue: 1)
    let surface = CGWindowRecord(
      id: 1,
      processID: 10,
      layer: 0,
      title: "Video",
      frame: Rect(x: 0, y: 33, width: 1_512, height: 949)
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
      ) == [windowID]
    )
    #expect(
      activeNativeFullscreenWindowIDs(
        processIDsByWindowID: [windowID: 10],
        cgWindows: [
          CGWindowRecord(
            id: surface.id,
            processID: surface.processID,
            layer: surface.layer,
            title: surface.title,
            frame: surface.frame,
            isOnscreen: false
          ),
          hiddenMenuBand,
        ],
        monitors: [monitor]
      ).isEmpty
    )
  }

  @MainActor
  @Test
  func automaticFocusWriteIsSkippedForFullscreenWindow() {
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

  @MainActor
  @Test
  func frameApplicationPreservesFullscreenTarget() {
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

  @MainActor
  @Test
  func fullscreenExitStartsFrameSettlement() {
    let windowID = WindowID(rawValue: 1)
    let platform = MacOSPlatform()
    platform.updateNativeFullscreenWindowIDs([windowID])
    #expect(platform.isInitialFrameSettlementActive(for: windowID))

    platform.updateNativeFullscreenWindowIDs([])

    #expect(platform.isInitialFrameSettlementActive(for: windowID))
  }

  @MainActor
  @Test
  func placeholderManagerTracksOnlyCurrentFullscreenSlots() {
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
      )
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
  func activeSpaceChangeForcesFreshTopology() {
    #expect(windowSnapshotInvalidation(for: .space, processID: nil) == .full)
    #expect(
      nativeFocusedWindowIDAfterEvent(
        .space,
        cachedWindowID: WindowID(rawValue: 1)
      ) == WindowID(rawValue: 1)
    )
  }

  @Test
  func transientSpaceGapDoesNotEmitAFullscreenExit() {
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
      now: 10.8
    )

    #expect(transitionGap.windowIDs == [windowID])
    #expect(exited.windowIDs.isEmpty)
  }

  @Test
  func inactiveSpaceRetainsFullscreenIdentityWhileProcessStillCoversDisplay() {
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
  func fullscreenSpaceRetainsFocusResourcesFromMaskedSpaces() {
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
