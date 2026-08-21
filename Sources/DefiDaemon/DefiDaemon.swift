import AppKit
import DefiConfig
import DefiCore
import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation
import OSLog

let performanceLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Performance"
)

@main
struct DefiDaemonMain {
  @MainActor
  static func main() {
    do {
      let options = try DaemonOptions(arguments: Array(CommandLine.arguments.dropFirst()))
      let daemon = try Daemon(options: options)
      daemon.run()
    } catch {
      FileHandle.standardError.write(Data("defi-daemon: \(error)\n".utf8))
      exit(1)
    }
  }
}

private struct DaemonOptions {
  let configURL: URL?
  let socketURL: URL

  init(arguments: [String]) throws {
    var configURL: URL?
    var socketURL = SocketPath.defaultURL
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--config":
        index += 1
        guard arguments.indices.contains(index) else {
          throw DaemonError.usage
        }
        configURL = URL(filePath: arguments[index])
      case "--socket":
        index += 1
        guard arguments.indices.contains(index) else {
          throw DaemonError.usage
        }
        socketURL = URL(filePath: arguments[index])
      case "--help", "-h":
        print("usage: defi-daemon [--config <path>] [--socket <path>]")
        exit(0)
      default:
        throw DaemonError.usage
      }
      index += 1
    }
    self.configURL = configURL
    self.socketURL = socketURL
  }
}

private enum DaemonError: Error, CustomStringConvertible {
  case usage

  var description: String {
    "usage: defi-daemon [--config <path>] [--socket <path>]"
  }
}

struct PendingAnimatedFocus: Equatable {
  let windowID: WindowID
  let previousSelectedWindowID: WindowID?
  let monitorID: MonitorID
  let sourceWorkspaceID: WorkspaceID
  let commandGeneration: UInt64
  let focusInputTimestamp: TimeInterval
  let cursorWarpInputTimestamp: TimeInterval?
  let retryCount: Int

  init(
    windowID: WindowID,
    previousSelectedWindowID: WindowID?,
    monitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?,
    retryCount: Int = 0
  ) {
    self.windowID = windowID
    self.previousSelectedWindowID = previousSelectedWindowID
    self.monitorID = monitorID
    self.sourceWorkspaceID = sourceWorkspaceID
    self.commandGeneration = commandGeneration
    self.focusInputTimestamp = focusInputTimestamp
    self.cursorWarpInputTimestamp = cursorWarpInputTimestamp
    self.retryCount = retryCount
  }
}

struct PendingWorkspaceFocus: Equatable {
  let monitorID: MonitorID
  let requestedWorkspaceID: WorkspaceID
  let previousWorkspaceID: WorkspaceID?
  let requestedWindowID: WindowID
  let restoresPreviousWorkspaceOnCancellation: Bool
  let commandGeneration: UInt64
  let focusInputTimestamp: TimeInterval
  let cursorWarpInputTimestamp: TimeInterval?
  let retryCount: Int

  init(
    monitorID: MonitorID,
    requestedWorkspaceID: WorkspaceID,
    previousWorkspaceID: WorkspaceID?,
    requestedWindowID: WindowID,
    restoresPreviousWorkspaceOnCancellation: Bool,
    commandGeneration: UInt64,
    focusInputTimestamp: TimeInterval,
    cursorWarpInputTimestamp: TimeInterval?,
    retryCount: Int = 0
  ) {
    self.monitorID = monitorID
    self.requestedWorkspaceID = requestedWorkspaceID
    self.previousWorkspaceID = previousWorkspaceID
    self.requestedWindowID = requestedWindowID
    self.restoresPreviousWorkspaceOnCancellation =
      restoresPreviousWorkspaceOnCancellation
    self.commandGeneration = commandGeneration
    self.focusInputTimestamp = focusInputTimestamp
    self.cursorWarpInputTimestamp = cursorWarpInputTimestamp
    self.retryCount = retryCount
  }
}

struct MonitorLayoutPlan {
  let assignments: [FrameAssignment]
  let borderAssignments: [FrameAssignment]
  let hiddenWindowIDs: Set<WindowID>
}

enum DisplacedPointerFocusRecovery: Equatable {
  case command(PendingAnimatedFocus, timestamp: TimeInterval)
  case workspace(PendingWorkspaceFocus, timestamp: TimeInterval)
}

@MainActor
final class Daemon: NSObject {
  let config: Config
  let platform = MacOSPlatform()
  let server: UnixSocketServer
  let placementStore: PlacementStore
  let diagnostics = DiagnosticRecorder()
  let readResponseCache = DaemonReadResponseCache()
  var state: RuntimeState
  var placementPreferences: PlacementPreferences
  var placementPreferencesDirty = false
  let placementSaveQueue = DispatchQueue(
    label: "com.quentin.defi.placements",
    qos: .utility
  )
  var placementSaveWorkItem: DispatchWorkItem?
  var hotKeys: HotKeyManager?
  var menuBar: MenuBarController?
  var lastPublishedWorkspaceState: WorkspaceStateSnapshot?
  var lastWorkspacePublishState: RuntimeState?
  var lastWorkspacePublishDisplayOrder: [MonitorID] = []
  var lastWorkspacePublishFocusedMonitorID: MonitorID?
  var timer: DispatchSourceTimer?
  var timerFrequencyHz = 2.0
  var tickScheduled = false
  var ipcSource: DispatchSourceRead?
  var nextPeriodicWindowRefreshAt: TimeInterval = 0
  var nextWindowListRefreshAt: TimeInterval = 0
  var nextApplicationInventoryRefreshAt: TimeInterval = 0
  var activeMonitorID: MonitorID?
  var latestMonitors: [MonitorSnapshot] = []
  var layoutPlansByMonitor: [MonitorID: MonitorLayoutPlan] = [:]
  var shouldShutdown = false
  var signalSources: [DispatchSourceSignal] = []
  var pendingHotKeyCommands: [HotKeyInvocation] = []
  var processingHotKeyCommands = false
  var processedHotKeyCount = 0
  var needsDesktopSync = true
  var axPrefetchInvalidationRetries = 0
  var cgPrefetchInvalidationRetries = 0
  var bypassPrefetchOnce = false
  var observedPlatformEventCount = 0
  var targetMismatchCount = 0
  var targetMismatches: [FrameMismatch] = []
  var activelyResizedWindowID: WindowID?
  var mouseGestureInitialFrame: Rect?
  var mouseGestureScrollAnchor: WorkspaceScrollAnchor?
  var mouseGestureDisplayedOriginFrames: [WindowID: Rect] = [:]
  var mouseGestureGeneration: UInt64 = 0
  var mouseGestureSettlement: MouseGestureSettlement?
  var mouseGesturePreempted = false
  var mouseReorderAnimationActive = false
  var persistentWidthDriftCounts: [WindowID: Int] = [:]
  var floatingWindowFrames: [WindowID: Rect] = [:]
  var scrollAnimations: [ScrollAnimationKey: ScrollAnimation] = [:]
  var animationFrameCount = 0
  var currentAnimationFrameCount = 0
  var lastAnimationFrameCount = 0
  var lastAnimationStepDurationMS = 0.0
  var maximumAnimationStepDurationMS = 0.0
  var lastAnimationDurationMS = 0.0
  var lastCommandDurationMS = 0.0
  var latestCommandInputTimestamp: TimeInterval = 0
  var commandGeneration: UInt64 = 0
  var deferredMouseFocusIntent: DeferredMouseFocusIntent?
  var consumedMouseFocusIntentTimestamp: TimeInterval = 0
  var suppressNativeFocusUntil: TimeInterval = 0
  var ignoredRedundantNativeFocusCount = 0
  var pendingWindowRemovalFocusGuard: WindowRemovalFocusGuard?
  var preservedWindowRemovalFocusCount = 0
  var pendingAnimatedFocus: PendingAnimatedFocus?
  var submittedCommandFocus: PendingAnimatedFocus?
  var pendingWorkspaceFocus: PendingWorkspaceFocus?
  var submittedWorkspaceFocusGeneration: UInt64?
  var submittedWorkspaceFocusRequestID: NativeFocusRequestID?
  var submittedWorkspaceFocusRequestTimestamp: TimeInterval?
  var submittedWorkspaceFocusRecoveryGeneration: UInt64?
  var nextWorkspaceFocusRecoveryGeneration: UInt64 = 0
  var displacedPointerFocusRecovery: DisplacedPointerFocusRecovery?
  var lastPointerWindowID: WindowID?
  var pendingPointerFocus: PendingPointerFocus?
  var pointerFocusGeneration: UInt64 = 0
  var submittedPointerFocusRequestID: NativeFocusRequestID?
  var submittedPointerFocusTimestamp: TimeInterval?
  var submittedPointerFocusGeneration: UInt64?
  var submittedPointerFocusRecoveryRequestID: NativeFocusRequestID?
  var submittedPointerFocusRecoveryTimestamp: TimeInterval?
  var submittedPointerFocusRecoveryGeneration: UInt64?
  var nextPointerFocusRecoveryGeneration: UInt64 = 0
  var submittedCommandFocusRequestID: NativeFocusRequestID?
  var submittedCommandFocusRequestTimestamp: TimeInterval?
  var submittedCommandFocusRecoveryGeneration: UInt64?
  var nextCommandFocusRecoveryGeneration: UInt64 = 0
  var lastRawPointerWindowID: WindowID?
  var pointerFocusObservedCount = 0
  var pointerFocusAppliedCount = 0
  var pointerFocusIgnoredCount = 0
  var frameNotificationsSuspended = false
  var displayedFrameRebaseCount = 0
  var lastDisplayedFrameRebaseDelta = 0.0
  var displayConfigurationEventCount = 0
  var pendingDisplaySyncDeadlines: [TimeInterval] = []
  var followUpTickSignature: String?
  var followUpBackoffSteps = 0

  fileprivate init(options: DaemonOptions) throws {
    config = try Config.load(from: options.configURL)
    server = try UnixSocketServer(url: options.socketURL)
    placementStore = PlacementStore()
    placementPreferences = (try? placementStore.load()) ?? PlacementPreferences()
    state = RuntimeState(config: config)
    super.init()
    platform.setCommandDiagnosticHandler { [weak diagnostics] sample in
      diagnostics?.record(sample)
    }
    platform.setDiagnosticAnomalyHandler { [weak diagnostics] uptime, event in
      diagnostics?.recordAnomaly(uptime: uptime, event: event)
    }
  }

  fileprivate func run() {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.finishLaunching()
    installSignalHandlers()
    let trusted = platform.accessibilityTrusted(prompt: true)
    if !trusted {
      log("Accessibility permission pending. Grant Defi access in System Settings.")
    }
    platform.startObserving(
      { [weak self] in
        self?.observedPlatformEventCount += 1
        self?.needsDesktopSync = true
        self?.scheduleTick()
      },
      displayConfigurationHandler: { [weak self] in
        self?.scheduleDisplayReconciliation()
      },
      mouseGestureStartedHandler: { [weak self] in
        self?.beginMouseGesture()
      },
      mouseGestureHandler: { [weak self] in
        self?.cancelAnimationForMouseGesture()
      }
    )

    let manager = HotKeyManager(
      config: config,
      userInputTracker: platform.userInputTracker,
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { [weak self] invocation in
        self?.handlePointerMotion(invocation)
      },
      tapReenabledHandler: { [weak self] timestamp in
        self?.handleEventTapReenabled(at: timestamp)
      }
    ) { [weak self] invocation in
      self?.enqueueHotKey(invocation)
    }
    do {
      try manager.start()
      hotKeys = manager
      if let bindingError = manager.bindingError {
        if manager.tracksPointerMotion {
          log("hotkeys unavailable: \(bindingError); pointer tracking remains enabled")
        } else {
          log("hotkeys unavailable: \(bindingError)")
        }
      }
    } catch {
      log("input event tap unavailable: \(error)")
    }
    if config.menuBar.enabled {
      menuBar = MenuBarController { [weak self] command in
        _ = self?.handle(command)
      }
    }
    installIPCSource()

    synchronizeDesktop(
      forceFullWindowRefresh: true,
      forceWindowListRefresh: true,
      forceApplicationInventoryRefresh: true
    )
    replaceTimer(frequencyHz: 2)
    log("running; socket=\(server.url.path)")
    NSApplication.shared.run()
  }

  func tick() {
    processPendingHotKeys()
    finishPendingAnimatedFocusIfReady()
    finishPendingWorkspaceFocusIfReady()
    finishPendingPointerFocusIfReady()
    if let deadline = pendingDisplaySyncDeadlines.first,
      ProcessInfo.processInfo.systemUptime >= deadline
    {
      pendingDisplaySyncDeadlines.removeFirst()
      needsDesktopSync = true
    }
    let now = ProcessInfo.processInfo.systemUptime
    if let mouseGestureSettlement,
      now >= mouseGestureSettlement.nextCheckAt
    {
      platform.requestFrameRefresh(for: mouseGestureSettlement.windowID)
      needsDesktopSync = true
    }
    if mouseReorderAnimationActive
      && !platform.hasPendingAnimatedFrameWrites
    {
      mouseReorderAnimationActive = false
    }
    let liveBorderGesture = platform.isLeftMouseButtonDown
    let mouseGestureSyncPending =
      needsDesktopSync
      && (liveBorderGesture || activelyResizedWindowID != nil)
    if mouseGestureSyncPending
      && (!scrollAnimations.isEmpty || platform.hasPendingAnimatedFrameWrites)
    {
      cancelAnimationForMouseGesture()
    }
    let animatedWritesPending = platform.hasPendingAnimatedFrameWrites
    let nativeFocusSyncPending = platform.hasPendingNativeFocusEvent
    if liveBorderGesture {
      setTimerFrequency(min(activeDisplayRefreshRate, 120))
    }
    if scrollAnimations.isEmpty && !animatedWritesPending && !liveBorderGesture {
      if frameNotificationsSuspended {
        platform.setFrameNotificationsEnabled(true)
        frameNotificationsSuspended = false
        needsDesktopSync = true
      }
      let followUpPending = needsDesktopSync
        || mouseGestureSettlement != nil
        || !pendingDisplaySyncDeadlines.isEmpty
        || pendingAnimatedFocus != nil
        || pendingWorkspaceFocus != nil
        || platform.hasPendingFocusWrite
        || platform.hasPendingFrameWrites
        || platform.hasPendingFrameDebt
        || platform.hasPendingTransientOwnerResolution
      // A single stuck slow-app write must not pin the timer at 60 Hz:
      // decay while the pending set is unchanged, reset on any movement.
      if followUpPending {
        let signature =
          "\(needsDesktopSync)|\(mouseGestureSettlement != nil)|\(pendingDisplaySyncDeadlines.count)|\(pendingAnimatedFocus != nil)|\(pendingWorkspaceFocus != nil)|\(platform.hasPendingFocusWrite)|\(platform.hasPendingFrameWrites)|\(platform.hasPendingFrameDebt)|\(platform.hasPendingTransientOwnerResolution)"
        if signature == followUpTickSignature {
          followUpBackoffSteps = min(followUpBackoffSteps + 1, 2)
        } else {
          followUpTickSignature = signature
          followUpBackoffSteps = 0
        }
        setTimerFrequency([60.0, 30.0, 15.0][followUpBackoffSteps])
      } else {
        followUpTickSignature = nil
        followUpBackoffSteps = 0
        setTimerFrequency(2)
      }
    }
    let userInputIdleDuration =
      now - platform.userInputTracker.latestEventTimestamp
    let desktopRefreshInterval = desktopSnapshotRefreshInterval(
      reliableDesktopObservation: platform.hasReliableDesktopObservation
    )
    let windowListRefreshInterval = platform.recommendedWindowListRefreshInterval
    let applicationInventoryInterval =
      platform.recommendedApplicationInventoryRefreshInterval
    let periodicWindowRefreshDue = observationWatchdogRefreshIsReady(
      due: now >= nextPeriodicWindowRefreshAt,
      interval: desktopRefreshInterval,
      userInputIdleDuration: userInputIdleDuration
    )
    let windowListRefreshDue = observationWatchdogRefreshIsReady(
      due: now >= nextWindowListRefreshAt,
      interval: windowListRefreshInterval,
      userInputIdleDuration: userInputIdleDuration
    )
    let applicationInventoryRefreshDue = observationWatchdogRefreshIsReady(
      due: now >= nextApplicationInventoryRefreshAt,
      interval: applicationInventoryInterval,
      userInputIdleDuration: userInputIdleDuration
    )
    let commandQuietPeriodElapsed =
      now - latestCommandInputTimestamp >= 0.3
    if desktopSynchronizationIsReady(
      scrollAnimationActive: !scrollAnimations.isEmpty,
      animatedWritesPending: animatedWritesPending,
      mouseGestureSyncPending: mouseGestureSyncPending,
      needsDesktopSync: needsDesktopSync,
      periodicSyncDue:
        periodicWindowRefreshDue
        || windowListRefreshDue
        || applicationInventoryRefreshDue,
      commandQuietPeriodElapsed: commandQuietPeriodElapsed,
      nativeFocusSyncPending: nativeFocusSyncPending,
      frameDebtPending: platform.hasPendingFrameDebt,
      lifecycleEventPending: platform.hasPendingWindowTopologyEvent
    ) {
      let forcesWindowInventory = !nativeFocusSyncPending
        && (windowListRefreshDue || applicationInventoryRefreshDue)
      let forceWindowListRefresh = !nativeFocusSyncPending
        && windowListRefreshDue
      let forceApplicationInventoryRefresh = !nativeFocusSyncPending
        && applicationInventoryRefreshDue
      let forcesFullWindowRefresh = !nativeFocusSyncPending
        && (forcesWindowInventory
          || (periodicWindowRefreshDue
            && !platform.hasReliableWindowTopologyObservation))
      if !mouseGestureSyncPending,
        !nativeFocusSyncPending,
        forcesFullWindowRefresh,
        !bypassPrefetchOnce,
        platform.prepareAXWindowAttributesIfNeeded(
          completion: { [weak self] published in
            guard let self else { return }
            if published {
              self.axPrefetchInvalidationRetries = 0
            } else {
              self.axPrefetchInvalidationRetries += 1
              if self.axPrefetchInvalidationRetries >= 2 {
                self.bypassPrefetchOnce = true
              }
            }
            self.needsDesktopSync = true
            self.scheduleTick()
          }
        )
      {
        return
      }
      if !mouseGestureSyncPending,
        !nativeFocusSyncPending,
        forcesFullWindowRefresh,
        !bypassPrefetchOnce,
        platform.prepareCGWindowInventoryIfNeeded(
          completion: { [weak self] published in
            guard let self else { return }
            if published {
              self.cgPrefetchInvalidationRetries = 0
            } else {
              self.cgPrefetchInvalidationRetries += 1
              if self.cgPrefetchInvalidationRetries >= 2 {
                self.bypassPrefetchOnce = true
              }
            }
            self.needsDesktopSync = true
            self.scheduleTick()
          }
        )
      {
        return
      }
      bypassPrefetchOnce = false
      needsDesktopSync = false
      synchronizeDesktop(
        forceFullWindowRefresh: forcesFullWindowRefresh,
        forceWindowListRefresh: forceWindowListRefresh,
        forceApplicationInventoryRefresh: forceApplicationInventoryRefresh,
        consumePeriodicWindowRefresh: periodicWindowRefreshDue
      )
      if platform.hasDeferredFreshWindowReads {
        needsDesktopSync = true
        setTimerFrequency(30)
        scheduleTick()
      }
    }
    if liveBorderGesture || animatedWritesPending {
      platform.refreshWindowBorders()
    }
  }
}
