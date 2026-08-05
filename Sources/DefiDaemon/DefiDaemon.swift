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

@MainActor
final class Daemon: NSObject {
  let config: Config
  let platform = MacOSPlatform()
  let server: UnixSocketServer
  let placementStore: PlacementStore
  var state: RuntimeState
  var placementPreferences: PlacementPreferences
  var hotKeys: HotKeyManager?
  var menuBar: MenuBarController?
  var timer: DispatchSourceTimer?
  var timerFrequencyHz = 60.0
  var activeMonitorID: MonitorID?
  var latestMonitors: [MonitorSnapshot] = []
  private var tickCount = 0
  var shouldShutdown = false
  var signalSources: [DispatchSourceSignal] = []
  var pendingHotKeyCommands: [String] = []
  var processingHotKeyCommands = false
  var processedHotKeyCount = 0
  var needsDesktopSync = true
  var observedPlatformEventCount = 0
  var targetMismatchCount = 0
  var targetMismatches: [FrameMismatch] = []
  var activelyResizedWindowID: WindowID?
  var mouseGestureInitialFrame: Rect?
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
  var suppressNativeFocusUntil: TimeInterval = 0
  var ignoredRedundantNativeFocusCount = 0
  var pendingWindowRemovalFocusGuard: WindowRemovalFocusGuard?
  var preservedWindowRemovalFocusCount = 0
  var pendingAnimatedFocusWindowID: WindowID?
  var deferredSlowWindowIDs = Set<WindowID>()
  var slowLaneSettlementDeadline: TimeInterval?
  var slowLaneDeferralCount = 0
  var slowLaneSettlementCount = 0
  var frameNotificationsSuspended = false
  var animationActivity: NSObjectProtocol?
  var displayedFrameRebaseCount = 0
  var lastDisplayedFrameRebaseDelta = 0.0
  var displayConfigurationEventCount = 0
  var pendingDisplaySyncDeadlines: [TimeInterval] = []

  fileprivate init(options: DaemonOptions) throws {
    config = try Config.load(from: options.configURL)
    server = try UnixSocketServer(url: options.socketURL)
    placementStore = PlacementStore()
    placementPreferences = (try? placementStore.load()) ?? PlacementPreferences()
    state = RuntimeState(config: config)
    super.init()
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
      },
      displayConfigurationHandler: { [weak self] in
        self?.scheduleDisplayReconciliation()
      },
      mouseGestureHandler: { [weak self] in
        self?.cancelAnimationForMouseGesture()
      }
    )

    do {
      let manager = try HotKeyManager(
        config: config,
        userInputTracker: platform.userInputTracker
      ) { [weak self] command in
        self?.enqueueHotKey(command)
      }
      try manager.start()
      hotKeys = manager
    } catch {
      log("hotkeys unavailable: \(error)")
    }
    menuBar = MenuBarController { [weak self] command in
      _ = self?.handle(command)
    }

    synchronizeDesktop()
    replaceTimer(frequencyHz: 60)
    log("running; socket=\(server.url.path)")
    NSApplication.shared.run()
  }

  func tick() {
    processPendingHotKeys()
    pollIPC()
    finishDeferredSlowLaneIfReady()
    finishPendingAnimatedFocusIfReady()
    if let deadline = pendingDisplaySyncDeadlines.first,
      ProcessInfo.processInfo.systemUptime >= deadline
    {
      pendingDisplaySyncDeadlines.removeFirst()
      needsDesktopSync = true
    }
    tickCount += 1
    let animatedWritesPending = platform.hasPendingAnimatedFrameWrites
    let liveBorderGesture = platform.isLeftMouseButtonDown
    if liveBorderGesture {
      setTimerFrequency(min(activeDisplayRefreshRate, 120))
    }
    if scrollAnimations.isEmpty && !animatedWritesPending && !liveBorderGesture {
      if let animationActivity {
        ProcessInfo.processInfo.endActivity(animationActivity)
        self.animationActivity = nil
      }
      if frameNotificationsSuspended {
        platform.setFrameNotificationsEnabled(true)
        frameNotificationsSuspended = false
        needsDesktopSync = true
      }
      setTimerFrequency(60)
    }
    if scrollAnimations.isEmpty && !animatedWritesPending
      && deferredSlowWindowIDs.isEmpty
      && (needsDesktopSync || tickCount.isMultiple(of: 18))
    {
      needsDesktopSync = false
      synchronizeDesktop()
    }
    platform.refreshWindowBorders()
  }
}
