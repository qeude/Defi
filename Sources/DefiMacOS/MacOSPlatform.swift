import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

@MainActor
public final class MacOSPlatform {
  var elements: [WindowID: AXUIElement] = [:]
  var processIDs: [WindowID: pid_t] = [:]
  var applications: [pid_t: AXUIElement] = [:]
  var applicationWindowCounts: [pid_t: Int] = [:]
  var enhancedUIByProcess: [pid_t: Bool] = [:]
  let frameCoordinator = AXFrameCoordinator()
  let focusWriter = AXFocusWriter()
  let borderManager = WindowBorderManager()
  let borderBoundsProvider = WindowServerBoundsProvider()
  var targetFrames: [WindowID: Rect] = [:]
  var pendingFrameCorrections: [WindowID: Rect] = [:]
  var latestObservedFrames: [WindowID: Rect] = [:]
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var newlyDiscoveredWindowIDs = Set<WindowID>()
  var hasCompletedWindowSnapshot = false
  var windowTopologyEventPending = false
  var pendingWindowTopologyProcessIDs = Set<pid_t>()
  var windowTopologyRequiresFullSnapshot = false
  var lastSnapshotWindows: [Window] = []
  var lastApplicationWindowElements: [pid_t: [AXUIElement]] = [:]
  var deferredFrameCommitMismatchCount = 0
  var observedFrameCommitCount = 0
  var maximumObservedFrameCommitLatencyMS = 0.0
  var lastHiddenWindowIDs = Set<WindowID>()
  var eventMonitor: PlatformEventMonitor?
  var frameEventPending = false
  var mouseResizeGesturePending = false
  var nativeFocusEventPending = false
  var nativeFocusRetryCount = 0
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var internalFocusDeadlines: [WindowID: TimeInterval] = [:]
  var positionWriteCount = 0
  var sizeWriteCount = 0
  var lastFrameApplyDurationMS = 0.0
  var lastMonitorFrames: [Rect] = []
  var borderFrames: [FrameAssignment] = []
  var borderSelectedWindowID: WindowID?
  var desiredSelectedWindowID: WindowID?
  var lastNativeFocusedWindowID: WindowID?
  var borderHiddenWindowIDs = Set<WindowID>()
  var borderLiveWindowID: WindowID?
  var frontmostNormalWindowID: WindowID?
  var borderStackingRefreshState = WindowBorderStackingRefreshState()
  var borderStackingRefreshTask: Task<Void, Never>?
  var borderStyle = WindowBorderStyle(
    enabled: true,
    width: 4,
    activeColor: 0xffc0_99ff,
    inactiveEnabled: false,
    inactiveColor: 0x66c0_99ff,
    captureEnabled: false
  )

  public init() {}

}
