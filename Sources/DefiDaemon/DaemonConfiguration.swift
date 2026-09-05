import Darwin
import DefiConfig
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

let windowCloseRefreshDelays = [50, 150, 350, 700, 1_200, 2_000]

func windowCloseTargetProcessID(
  eventTargetProcessID: pid_t?,
  selectedProcessID: pid_t?
) -> pid_t? {
  eventTargetProcessID ?? selectedProcessID
}

func windowCloseRetryIsCurrent(
  intentTimestamp: TimeInterval,
  latestInputTimestamp: TimeInterval,
  latestCloseIntentTimestamp: TimeInterval
) -> Bool {
  latestCloseIntentTimestamp == intentTimestamp
    && latestInputTimestamp <= intentTimestamp
}

@MainActor
final class ConfigFileWatcher {
  private let configURL: URL
  private let changeHandler: @MainActor @Sendable () -> Void
  private var directorySource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var reloadGeneration: UInt64 = 0

  init(configURL: URL, changeHandler: @escaping @MainActor @Sendable () -> Void) {
    self.configURL = configURL
    self.changeHandler = changeHandler
  }

  func start() throws {
    guard directorySource == nil else { return }
    let directoryURL = configURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    let descriptor = open(directoryURL.path, O_EVTONLY)
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.scheduleReload()
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    directorySource = source
    source.resume()
    replaceFileSource()
  }

  func stop() {
    reloadGeneration &+= 1
    fileSource?.cancel()
    fileSource = nil
    directorySource?.cancel()
    directorySource = nil
  }

  private func scheduleReload() {
    reloadGeneration &+= 1
    let generation = reloadGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, generation == self.reloadGeneration else { return }
        self.replaceFileSource()
        self.changeHandler()
      }
    }
  }

  private func replaceFileSource() {
    fileSource?.cancel()
    fileSource = nil
    let descriptor = open(configURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        self?.scheduleReload()
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    fileSource = source
    source.resume()
  }
}

@MainActor
extension Daemon {
  func startConfigWatcher() {
    let watcher = ConfigFileWatcher(configURL: configURL) { [weak self] in
      self?.reloadConfiguration()
    }
    do {
      try watcher.start()
      configWatcher = watcher
    } catch {
      log("config watcher unavailable for \(configURL.path): \(error)")
    }
  }

  func reloadConfiguration() {
    do {
      let nextConfig = try Config.load(from: configURL)
      guard nextConfig != config else { return }
      applyConfiguration(nextConfig)
      log("config reloaded")
    } catch {
      log("config reload failed; keeping previous configuration: \(error)")
    }
  }

  private func applyConfiguration(_ nextConfig: Config) {
    let previousConfig = config
    let previousViewports = viewportsByMonitor
    let previousFloatingMonitorIDs = Dictionary(
      uniqueKeysWithValues: floatingWindowFrames.keys.compactMap { windowID in
        state.monitorID(containing: windowID).map { (windowID, $0) }
      }
    )
    let requiresLayout = state.applyConfiguration(nextConfig)
    config = nextConfig
    configGeneration &+= 1

    handleCheatsheetInput(.dismiss)
    cheatsheetController = nil
    if hotKeyConfigurationChanged(from: previousConfig, to: nextConfig) {
      hotKeys?.stop()
      hotKeys = nil
      pendingHotKeyCommands.removeAll(keepingCapacity: true)
      installHotKeys()
      hotKeys?.setOverviewModeEnabled(overviewController?.isOpen == true)
    }
    if previousConfig.menuBar != nextConfig.menuBar {
      updateMenuBarAvailability()
    }

    let nextViewports = viewportsByMonitor
    let viewportsChanged = previousViewports != nextViewports
    let bordersChanged =
      previousConfig.decorations.borders
      != nextConfig.decorations.borders
    if requiresLayout || viewportsChanged || bordersChanged {
      rebaseFloatingWindowFrames(
        previousViewports: previousViewports,
        nextViewports: nextViewports,
        previousMonitorIDs: previousFloatingMonitorIDs
      )
      synchronizeScrollOffsets(state: &state, viewports: nextViewports)
      snapScrollOffsetsToTargets()
      applyCurrentLayout(
        asynchronousPositions: true,
        updateVisibility: true,
        positionTimeoutSeconds: 0.05,
        forceFloatingFrameWrites: viewportsChanged,
        source: "config-reload"
      )
    }

    updateOverviewIfOpen()
    updateMenuBar()
    persistTopology()
    if previousConfig.rules != nextConfig.rules {
      synchronizeDesktop(
        forceFullWindowRefresh: true,
        forceWindowListRefresh: true,
        forceApplicationInventoryRefresh: true
      )
    }
  }

  private func hotKeyConfigurationChanged(from previous: Config, to next: Config) -> Bool {
    previous.keys != next.keys
      || previous.modifierCombinations != next.modifierCombinations
      || previous.defaultKeyModifier != next.defaultKeyModifier
      || previous.showCheatsheetOnModifierHold != next.showCheatsheetOnModifierHold
      || previous.input.focusFollowsMouse != next.input.focusFollowsMouse
      || previous.input.mouseFollowsFocus != next.input.mouseFollowsFocus
  }

  func installHotKeys() {
    hotKeyGeneration &+= 1
    let generation = hotKeyGeneration
    let manager = HotKeyManager(
      config: config,
      userInputTracker: platform.userInputTracker,
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { [weak self] invocation in
        guard self?.desktopSessionActive == true else { return }
        self?.handlePointerMotion(invocation)
      },
      tapReenabledHandler: { [weak self] timestamp in
        self?.handleEventTapReenabled(at: timestamp)
      },
      closeIntentHandler: { [weak self] timestamp, targetProcessID in
        guard let self, desktopSessionActive else { return }
        let selectedWindowID = activeMonitorID
          .flatMap { state.selectedWindowID(on: $0) }
        let selectedProcessID = selectedWindowID
          .flatMap { state.windows[$0]?.processID }
        guard let processID = windowCloseTargetProcessID(
          eventTargetProcessID: targetProcessID,
          selectedProcessID: selectedProcessID
        )
        else { return }
        let previousWindowCount = state.windows.values.lazy.filter {
          $0.processID == processID
        }.count
        let trackedWindowID = selectedProcessID == processID
          ? selectedWindowID
          : nil
        for delay in windowCloseRefreshDelays {
          DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(delay)
          ) {
            let input = self.platform.userInputTracker.snapshot
            guard self.desktopSessionActive,
              windowCloseRetryIsCurrent(
                intentTimestamp: timestamp,
                latestInputTimestamp: input.latestEventTimestamp,
                latestCloseIntentTimestamp: input.latestCloseIntent
              ),
              trackedWindowID.map({ self.state.windows[$0] != nil }) ?? true,
              self.state.windows.values.lazy.filter({
                $0.processID == processID
              }).count >= previousWindowCount
            else { return }
            self.platform.recordPerformanceTrace(
              "window-close-retry pid=\(processID) delay=\(delay)"
            )
            self.platform.requestWindowTopologyRefresh(
              processID: processID,
              inputTimestamp: timestamp
            )
            self.needsDesktopSync = true
            self.scheduleTick()
          }
        }
      },
      overviewHandler: { [weak self] action in
        guard self?.desktopSessionActive == true else { return }
        self?.handleCheatsheetInput(.dismiss)
        self?.overviewController?.handleKey(action)
      },
      cheatsheetHandler: { [weak self] input in
        guard let self, self.hotKeyGeneration == generation else { return }
        self.handleCheatsheetInput(input)
      }
    ) { [weak self] invocation in
      self?.enqueueHotKey(invocation)
    }
    do {
      try manager.start()
      hotKeys = manager
      if let bindingError = manager.bindingError {
        presentDefiConfigurationError(bindingError)
        if manager.tracksPointerMotion {
          log("hotkeys unavailable: \(bindingError); pointer tracking remains enabled")
        } else {
          log("hotkeys unavailable: \(bindingError)")
        }
      }
    } catch {
      log("input event tap unavailable: \(error)")
    }
  }

  func updateMenuBarAvailability() {
    menuBar.isInserted = config.menuBar.enabled
  }

  func handleMenuCommand(_ command: String) {
    if command == "quit" {
      requestShutdown()
    } else {
      _ = handle(command)
    }
  }
}
