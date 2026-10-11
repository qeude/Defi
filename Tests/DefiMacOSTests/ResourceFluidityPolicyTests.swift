import AppKit
import ApplicationServices
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing
@testable import DefiMacOS

struct ResourceFluidityPolicyTests {
  @MainActor @Test func borderTranslationKeepsFramesAndRepairsStacking() {
    var now = 0.0
    let overlay = BorderOverlay(windowID: WindowID(rawValue: 1), now: { now })
    defer { overlay.hide() }
    func move(_ x: Double) {
      overlay.sync(frame: Rect(x: x, y: 100, width: 800, height: 600), width: 4,
        color: 0xffff_ffff, windowRadius: 12, captureEnabled: false, placement: .inside)
      overlay.applyCompositorFallback()
    }
    move(100)
    let panels = NSApp.windows.filter { overlay.windowIDs.contains(CGWindowID($0.windowNumber)) }
      .sorted { $0.windowNumber < $1.windowNumber }
    let initialFrames = panels.map(\.frame)
    #expect(overlay.orderingCount == 4)
    now = 0.5
    move(120)
    #expect(overlay.orderingCount == 4)
    #expect(panels.map(\.frame) == initialFrames.map { $0.offsetBy(dx: 20, dy: 0) })
    now = 1
    overlay.applyCompositorFallback()
    #expect(overlay.orderingCount == 8)
    overlay.retarget(to: WindowID(rawValue: 2), preservingBacking: true)
    move(120)
    #expect(overlay.orderingCount == 12)
    #expect(panels.allSatisfy { $0.isVisible && $0.alphaValue == 1 })
  }

  @Test func fallbackEventsAndGlobalRecoveryBypassPerProcessDeadlines() {
    var deadlines: [pid_t: TimeInterval] = [:]
    func due(_ now: Double, uncovered: Set<pid_t> = [41, 42], events: Set<pid_t> = [], force: Bool = false) -> Set<pid_t> {
      fallbackWindowRefreshProcessIDs(uncovered: uncovered, incompatible: [42],
        eventProcessIDs: events, force: force, now: now, deadlines: &deadlines)
    }
    #expect(due(0) == [41, 42])
    #expect(due(0.01).isEmpty)
    #expect(due(0.02, events: [41]) == [41])
    #expect(due(0.3).isEmpty)
    #expect(due(0.32) == [41])
    #expect(due(0.33, force: true) == [41, 42])
    #expect(due(0.34, uncovered: [42]).isEmpty)
    #expect(deadlines[41] == nil)
    #expect(due(30.33, uncovered: [42]) == [42])
    #expect(windowListRefreshInterval(hasPendingShortRetry: false, reliableTopologyObservation: false) == 0.3)
    #expect(windowListRefreshInterval(hasPendingShortRetry: false, reliableTopologyObservation: false,
      hasScopedTopologyFallback: true) == 30)
    #expect(windowListRefreshInterval(hasPendingShortRetry: true, reliableTopologyObservation: false,
      hasScopedTopologyFallback: true) == 0.1)
  }

  @MainActor @Test func scopedFallbackDiscoversNewWindowsWithoutReadingCoveredApplications() {
    let platform = NavigationActor.shared.queue.sync { NavigationActor.assumeIsolated { MacOSPlatform() } }
    let engine = platform.snapshotEngine
    let fixture = DiscoveryReadFixture()
    fixture.failsProcess = nil
    fixture.state.withLock { $0.now = 0.3 }
    engine.discoveryMeasurementAccess = fixture.access()
    engine.applications = [41: AXUIElementCreateApplication(-41), 42: AXUIElementCreateApplication(-42)]
    engine.applicationIDsByProcess = [41: "app-41", 42: "app-42"]
    engine.enhancedUIByProcess = [41: false, 42: false]
    engine.lastApplicationWindowElements = [41: [], 42: []]
    engine.hasCompletedWindowSnapshot = true
    var deadlines: [pid_t: TimeInterval] = [:]
    let due = fallbackWindowRefreshProcessIDs(uncovered: [42], incompatible: [], eventProcessIDs: [],
      force: false, now: 0.3, deadlines: &deadlines)
    let result = engine.discoverSnapshotWindows(monitors: [],
      config: Config(rules: [Rule(appID: "app-42", floating: true)]), incrementalProcessIDs: due,
      forceWindowListRefresh: false, forceWindowListRefreshProcessIDs: due.intersection([42]),
      forceApplicationInventoryRefresh: false, capturedTopologyRequiresFullSnapshot: false,
      topologyProcessIDs: [], createdElements: [:], preparedWindowAttributes: [:],
      preparedTransientOwnerWindowIDs: [:], preparedApplicationWindows: [:], explicitlyDestroyedWindowIDs: [],
      publicCGWindows: { [CGWindowRecord(id: 42001, processID: 42, layer: 0, title: "new",
        frame: fixture.frame, isOnscreen: true)] })
    #expect(result.windows.map(\.id) == [WindowID(rawValue: 42001)])
    #expect(fixture.state.withLock { $0.listCalls[42] } == 1)
    #expect(fixture.state.withLock { $0.listCalls[41] ?? 0 } == 0)
  }
}
