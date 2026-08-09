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
  var floatingWindowIDs = Set<WindowID>()
  var applications: [pid_t: AXUIElement] = [:]
  var applicationWindowCounts: [pid_t: Int] = [:]
  var enhancedUIByProcess: [pid_t: Bool] = [:]
  let frameCoordinator = AXFrameCoordinator()
  let focusWriter = AXFocusWriter()
  let focusRecoveryResolver = AXFocusRecoveryResolver()
  let borderManager = WindowBorderManager()
  let borderBoundsProvider = WindowServerBoundsProvider()
  var targetFrames: [WindowID: Rect] = [:]
  var pendingFrameDebtWindowIDs = Set<WindowID>()
  var pendingFrameCorrections: [WindowID: Rect] = [:]
  var latestObservedFrames: [WindowID: Rect] = [:]
  var frameCommitExpectations: [WindowID: FrameCommitExpectation] = [:]
  var initialFrameSettlementDeadlines: [WindowID: TimeInterval] = [:]
  var newlyDiscoveredWindowIDs = Set<WindowID>()
  var hasCompletedWindowSnapshot = false
  var windowTopologyEventPending = false
  var pendingWindowTopologyProcessIDs = Set<pid_t>()
  var windowTopologyRequiresFullSnapshot = false
  var pendingWindowTopologyInputTimestamp: TimeInterval?
  var pendingFrameProcessIDs = Set<pid_t>()
  var pendingFrameRequiresFullSnapshot = false
  var lastSnapshotWindows: [Window] = []
  var lastSnapshotWindowIDs = Set<WindowID>()
  var lastSnapshotProcessIDs = Set<pid_t>()
  var lastApplicationWindowElements: [pid_t: [AXUIElement]] = [:]
  var retainedWindowIDs = Set<WindowID>()
  var deferredFrameCommitMismatchCount = 0
  var observedFrameCommitCount = 0
  var maximumObservedFrameCommitLatencyMS = 0.0
  var lastHiddenWindowIDs = Set<WindowID>()
  var eventMonitor: PlatformEventMonitor?
  var frameEventPending = false
  var mouseResizeGesturePending = false
  var mouseFocusReleasePending = false
  var nativeFocusEventPending = false
  var nativeFocusEventProcessIDs = Set<pid_t>()
  var nativeFocusEventHasUnknownProcess = false
  var lastFocusedWindowByProcess: [pid_t: WindowID] = [:]
  var internalFocusSuppressions: [WindowID: InternalFocusSuppression] = [:]
  var nextInternalFocusRequestID: UInt64 = 0
  var positionWriteCount = 0
  var sizeWriteCount = 0
  var lastFrameApplyDurationMS = 0.0
  var lastMonitorFrames: [Rect] = []
  var pointerHitTestRecords: [CGWindowRecord] = []
  var pointerHitTestDockProcessIDs = Set<pid_t>()
  var pointerHitTestSnapshotTimestamp: TimeInterval?
  var borderFrames: [FrameAssignment] = []
  var borderSelectedWindowID: WindowID?
  var desiredSelectedWindowID: WindowID?
  var lastNativeFocusedWindowID: WindowID?
  var borderHiddenWindowIDs = Set<WindowID>()
  var borderLiveWindowID: WindowID?
  var windowBorderStacking = WindowBorderStacking.inactive(for: nil)
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
  var cursorWarpAppliedCount = 0
  var cursorWarpSkippedCount = 0
  var cursorWarpFailedCount = 0

  public let userInputTracker = UserInputTracker()
  public let pointerMotionTracker = PointerMotionTracker()

  public init() {}

}
