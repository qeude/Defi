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

struct DaemonOptions {
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

struct MonitorLayoutPlan {
  let assignments: [FrameAssignment]
  let borderAssignments: [FrameAssignment]
  let nativeFullscreenPlaceholderAssignments: [FrameAssignment]
  let hiddenWindowIDs: Set<WindowID>
}

struct WorkspaceTransitionIntent: Equatable {
  let monitorID: MonitorID
  let outgoingWorkspaceID: WorkspaceID
  let incomingWorkspaceID: WorkspaceID
  let direction: Int
}

struct WorkspaceVerticalTransition: Equatable {
  let monitorID: MonitorID
  let outgoingWorkspaceID: WorkspaceID
  let direction: Int
}

@MainActor
final class Daemon: NSObject {
  let configURL: URL
  var config: Config
  let platform = MacOSPlatform()
  let server: UnixSocketServer
  let placementStore: PlacementStore
  let topologyStore: WorkspaceTopologyStore
  let topologySessionID: String
  let diagnostics = DiagnosticRecorder()
  let readResponseCache = DaemonReadResponseCache()
  var focus = FocusState()
  var state: RuntimeState
  var placementPreferences: PlacementPreferences
  var placementPreferencesDirty = false
  let placementSaveQueue = DispatchQueue(
    label: "com.quentin.defi.placements",
    qos: .utility
  )
  var placementSaveWorkItem: DispatchWorkItem?
  var topologySaveWorkItem: DispatchWorkItem?
  var lastPersistedTopology: WorkspaceTopology?
  var hotKeys: HotKeyManager?
  var overviewController: OverviewController?
  var cheatsheetState = CheatsheetState()
  var cheatsheetController: CheatsheetController?
  var cheatsheetHoldTask: Task<Void, Never>?
  var hotKeyGeneration: UInt64 = 0
  var overviewOpenedAt: TimeInterval?
  let menuBar = MenuBarState()
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
  var configWatcher: ConfigFileWatcher?
  var configGeneration: UInt64 = 0
  var pendingHotKeyCommands: [HotKeyInvocation] = []
  var processingHotKeyCommands = false
  var processedHotKeyCount = 0
  var needsDesktopSync = true
  var desktopSessionActive = true
  var desktopSessionGeneration: UInt64 = 0
  var desktopSnapshotInFlight = false
  var supersededDesktopSnapshotRequest:
    (
      forceFullWindowRefresh: Bool,
      forceWindowListRefresh: Bool,
      forceApplicationInventoryRefresh: Bool,
      consumePeriodicWindowRefresh: Bool
    )?
  var axPrefetchInvalidationRetries = 0
  var cgPrefetchInvalidationRetries = 0
  var bypassPrefetchOnce = false
  var observedPlatformEventCount = 0
  var targetMismatches: [FrameMismatch] = []
  var activelyResizedWindowID: WindowID?
  var mouseGestureInitialFrame: Rect?
  var mouseGestureScrollAnchor: WorkspaceScrollAnchor?
  var mouseGestureDisplayedOriginFrames: [WindowID: Rect] = [:]
  var mouseGestureGeneration: UInt64 = 0
  var mouseGestureSettlement: MouseGestureSettlement?
  var mouseGesturePreempted = false
  var mouseReorderAnimationActive = false
  var floatingWindowFrames: [WindowID: Rect] = [:]
  var scrollAnimations: [ScrollAnimationKey: ScrollAnimation] = [:]
  var lastAnimationFrameCount = 0
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
  var pendingAnimatedFocus: PendingAnimatedFocus? { focus.pendingAnimatedFocus }
  var submittedCommandFocus: PendingAnimatedFocus? { focus.submittedCommandFocus }
  var pendingWorkspaceFocus: PendingWorkspaceFocus? { focus.pendingWorkspaceFocus }
  var submittedWorkspaceFocusGeneration: UInt64? { focus.submittedWorkspaceFocusGeneration }
  var submittedWorkspaceFocusRequestID: NativeFocusRequestID?
  var submittedWorkspaceFocusRequestTimestamp: TimeInterval?
  var submittedWorkspaceFocusRecoveryGeneration: UInt64?
  var nextWorkspaceFocusRecoveryGeneration: UInt64 = 0
  var displacedPointerFocusRecovery: DisplacedPointerFocusRecovery? {
    focus.displacedPointerFocusRecovery
  }
  var lastPointerWindowID: WindowID? { focus.lastPointerWindowID }
  var pendingPointerFocus: PendingPointerFocus? { focus.pendingPointerFocus }
  var submittedPointerFocusRequestID: NativeFocusRequestID?
  var submittedPointerFocusTimestamp: TimeInterval?
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
  var followUpUnchangedSince: TimeInterval = 0

  init(options: DaemonOptions) throws {
    configURL = options.configURL ?? Config.defaultURL
    config = try Config.load(from: configURL)
    server = try UnixSocketServer(url: options.socketURL)
    placementStore = PlacementStore()
    topologyStore = WorkspaceTopologyStore()
    topologySessionID = String(audit_session_self())
    placementPreferences = (try? placementStore.load()) ?? PlacementPreferences()
    let restoredTopology = try? topologyStore.load(sessionID: topologySessionID)
    state = RuntimeState(config: config, topology: restoredTopology)
    lastPersistedTopology = restoredTopology
    super.init()
    platform.setCommandDiagnosticHandler { [weak diagnostics] sample in
      diagnostics?.record(sample)
    }
    platform.setDiagnosticAnomalyHandler { [weak diagnostics] uptime, event in
      diagnostics?.recordAnomaly(uptime: uptime, event: event)
    }
  }

  func start() {
    installSignalHandlers()
    let trusted = platform.accessibilityTrusted(prompt: true)
    if !trusted {
      log("Accessibility permission pending. Grant Defi access in System Settings.")
    }
    platform.startObserving(
      { [weak self] in
        guard let self, desktopSessionActive else { return }
        observedPlatformEventCount += 1
        needsDesktopSync = true
        scheduleTick()
      },
      desktopSessionHandler: { [weak self] active in
        self?.handleDesktopSessionActivity(active)
      },
      displayConfigurationHandler: { [weak self] in
        guard self?.desktopSessionActive == true else { return }
        self?.scheduleDisplayReconciliation()
      },
      mouseGestureStartedHandler: { [weak self] in
        guard self?.desktopSessionActive == true else { return }
        self?.beginMouseGesture()
      },
      mouseGestureHandler: { [weak self] in
        guard self?.desktopSessionActive == true else { return }
        self?.cancelAnimationForMouseGesture()
      }
    )

    installHotKeys()
    updateMenuBarAvailability()
    startConfigWatcher()
    installIPCSource()

    synchronizeDesktop(
      forceFullWindowRefresh: true,
      forceWindowListRefresh: true,
      forceApplicationInventoryRefresh: true
    )
    replaceTimer(frequencyHz: 2)
    log("running; socket=\(server.url.path)")
  }

  func handleDesktopSessionActivity(_ active: Bool) {
    guard desktopSessionActive != active else { return }
    desktopSessionActive = active
    if !active { handleCheatsheetInput(.dismiss) }
    desktopSessionGeneration &+= 1
    guard active else {
      commandGeneration &+= 1
      mouseGestureGeneration &+= 1
      pendingHotKeyCommands.removeAll(keepingCapacity: true)
      focus.interrupt()
      invalidateSubmittedCommandFocus()
      invalidateSubmittedWorkspaceFocus()
      cancelSubmittedPointerFocus()
      rearmPointerFocusTransition()
      scrollAnimations.removeAll(keepingCapacity: true)
      finishMouseGestureTracking()
      mouseReorderAnimationActive = false
      frameNotificationsSuspended = false
      pendingDisplaySyncDeadlines.removeAll(keepingCapacity: true)
      supersededDesktopSnapshotRequest = nil
      needsDesktopSync = false
      followUpTickSignature = nil
      followUpBackoffSteps = 0
      platform.invalidateStateForDesktopSessionChange()
      replaceTimer(frequencyHz: 2)
      log("desktop session inactive")
      return
    }

    replaceTimer(frequencyHz: 2)
    needsDesktopSync = true
    synchronizeDesktop(
      forceFullWindowRefresh: true,
      forceWindowListRefresh: true,
      forceApplicationInventoryRefresh: true
    )
    scheduleTick()
    log("desktop session active; refreshing desktop")
  }

  func tick() {
    guard desktopSessionActive else { return }
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
    let recentCommandAnimationInputTimestamp =
      animatedWritesPending
        && now - latestCommandInputTimestamp < 0.3
      ? latestCommandInputTimestamp
      : nil
    let pendingCommandFocusInputTimestamp = [
      pendingAnimatedFocus?.focusInputTimestamp,
      submittedCommandFocus?.focusInputTimestamp,
      pendingWorkspaceFocus?.focusInputTimestamp,
      submittedCommandFocusRequestTimestamp,
      submittedWorkspaceFocusRequestTimestamp,
      recentCommandAnimationInputTimestamp,
    ].compactMap { $0 }.max()
    let latestFocusIntentTimestamp = max(
      platform.userInputTracker.snapshot.latestFocusIntent?.timestamp ?? 0,
      platform.userInputTracker.pendingApplicationActivation(
        frontmostProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
      )?.timestamp ?? 0
    )
    let nativeFocusHasNewerHumanIntent =
      pendingCommandFocusInputTimestamp.map {
        latestFocusIntentTimestamp > $0
      } ?? true
    if liveBorderGesture {
      setTimerFrequency(min(activeDisplayRefreshRate, 120))
    }
    if scrollAnimations.isEmpty && !animatedWritesPending && !liveBorderGesture {
      if frameNotificationsSuspended {
        platform.setFrameNotificationsEnabled(true)
        frameNotificationsSuspended = false
        needsDesktopSync = true
      }
      let followUpPending =
        needsDesktopSync
        || mouseGestureSettlement != nil
        || !pendingDisplaySyncDeadlines.isEmpty
        || pendingAnimatedFocus != nil
        || pendingWorkspaceFocus != nil
        || pendingPointerFocus != nil
        || platform.hasPendingFocusWrite
        || platform.hasPendingFrameWrites
        || platform.hasPendingFrameDebt
        || platform.hasPendingTransientOwnerResolution
      // A single stuck slow-app write must not pin the timer at 60 Hz:
      // decay while the pending set is unchanged, reset on any movement.
      if followUpPending {
        let focusPending = pendingAnimatedFocus != nil || pendingWorkspaceFocus != nil
          || pendingPointerFocus != nil || platform.hasPendingFocusWrite
        let signature =
          "\(needsDesktopSync)|\(mouseGestureSettlement != nil)|\(pendingDisplaySyncDeadlines.count)|\(pendingAnimatedFocus != nil)|\(pendingWorkspaceFocus != nil)|\(pendingPointerFocus != nil)|\(platform.hasPendingFocusWrite)|\(platform.hasPendingFrameWrites)|\(platform.hasPendingFrameDebt)|\(platform.hasPendingTransientOwnerResolution)|\(observedPlatformEventCount)|\(platform.successfulPositionWriteCount)"
        if signature == followUpTickSignature {
          followUpBackoffSteps = min(followUpBackoffSteps + 1, 2)
        } else {
          followUpTickSignature = signature
          followUpBackoffSteps = 0
          followUpUnchangedSince = now
        }
        setTimerFrequency(followUpTimerFrequency(
          backoffSteps: followUpBackoffSteps,
          unchangedDuration: now - followUpUnchangedSince,
          focusPending: focusPending
        ))
      } else {
        followUpTickSignature = nil
        followUpBackoffSteps = 0
        scheduleIdleTick()
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
      nativeFocusHasNewerHumanIntent: nativeFocusHasNewerHumanIntent,
      frameDebtPending: platform.hasPendingFrameDebt,
      lifecycleEventPending: platform.hasPendingWindowTopologyEvent
    ) {
      let forcesWindowInventory =
        !nativeFocusSyncPending
        && (windowListRefreshDue || applicationInventoryRefreshDue)
      let forceWindowListRefresh =
        !nativeFocusSyncPending
        && windowListRefreshDue
      let forceApplicationInventoryRefresh =
        !nativeFocusSyncPending
        && applicationInventoryRefreshDue
      let forcesFullWindowRefresh =
        !nativeFocusSyncPending
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
      if platform.hasDeferredFreshWindowReads
        || platform.hasChunkedFullRefreshPending
      {
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
