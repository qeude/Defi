import AppKit
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import QuartzCore

private let overviewOpeningLogger = Logger(subsystem: "com.quentin.defi", category: "OverviewOpening")

let overviewTransitionDuration: TimeInterval = 0.16
let overviewOpenFadeDuration: TimeInterval = 0.14
let overviewDesktopFadeDuration: TimeInterval = 0.25

private struct OverviewViewportAnimation {
  let from: OverviewViewport
  let to: OverviewViewport
  let startedAt: TimeInterval
  let duration: TimeInterval
}

private struct OverviewProjectionAnimation {
  let from: OverviewProjection
  let to: OverviewProjection
  let startedAt: TimeInterval
  let duration: TimeInterval
}



enum OverviewScrollAxis: Equatable {
  case horizontal
  case vertical
}

func overviewScrollAxis(for delta: NSPoint) -> OverviewScrollAxis? {
  guard delta.x != 0 || delta.y != 0 else { return nil }
  return abs(delta.y) >= abs(delta.x) ? .vertical : .horizontal
}

func overviewUsesWorkspaceParking(
  windowPreviewsEnabled: Bool,
  screenCaptureAccessGranted: Bool
) -> Bool {
  !windowPreviewsEnabled || !screenCaptureAccessGranted
}

func overviewShouldRequestCapturePermission(
  screenCaptureAccessGranted: Bool,
  ribbonPrototype: Bool,
  hasRequestedPermission: Bool
) -> Bool {
  !screenCaptureAccessGranted && !ribbonPrototype && !hasRequestedPermission
}

func overviewViewportAfterScroll(
  _ viewport: OverviewViewport,
  delta: NSPoint,
  hasPreciseScrollingDeltas: Bool,
  viewSize: NSSize,
  zoom: Double = 0.5,
  activeWorkspaceIndex: Int,
  workspaceCount: Int,
  horizontalWorkspaceID: WorkspaceID?,
  maximumHorizontalOffset: Double?
) -> OverviewViewport {
  var viewport = viewport
  let deltaScale = hasPreciseScrollingDeltas ? 1.0 : 16.0
  switch overviewScrollAxis(for: delta) {
  case .vertical:
    let stride = overviewWorkspaceStride(boundsHeight: viewSize.height, zoom: zoom)
    viewport.workspaceOffset = min(
      max(
        viewport.workspaceOffset - delta.y * deltaScale / max(stride, 1),
        Double(-activeWorkspaceIndex)
      ),
      Double(workspaceCount - activeWorkspaceIndex - 1)
    )
  case .horizontal:
    guard let horizontalWorkspaceID, let maximumHorizontalOffset else {
      return viewport
    }
    let workspaceHeight = overviewWorkspaceStride(
      boundsHeight: viewSize.height,
      zoom: zoom
    ) - 28
    let contentScale = workspaceHeight / max(viewSize.height, 1)
    let projectedPointsPerScrollUnit = viewSize.width * contentScale
    let offset = viewport.horizontalOffsets[horizontalWorkspaceID, default: 0]
      - delta.x * deltaScale / max(projectedPointsPerScrollUnit, 1)
    viewport.horizontalOffsets[horizontalWorkspaceID] = min(
      max(offset, 0),
      maximumHorizontalOffset
    )
  case nil:
    break
  }
  return viewport
}

func overviewViewportTransitionAfterSelectionAlignment(
  current: OverviewViewport,
  pendingTarget: OverviewViewport?,
  animationTarget: OverviewViewport?,
  workspaceID: WorkspaceID,
  scrollOffset: Double,
  sourceWorkspaceID: WorkspaceID?,
  sourceMaximumHorizontalOffset: Double?,
  movedSelection: Bool
) -> (current: OverviewViewport, target: OverviewViewport?) {
  var aligned = pendingTarget ?? animationTarget ?? current
  aligned.horizontalOffsets[workspaceID] = scrollOffset
  if let sourceWorkspaceID, let sourceMaximumHorizontalOffset {
    aligned.horizontalOffsets[sourceWorkspaceID] = min(
      max(aligned.horizontalOffsets[sourceWorkspaceID, default: 0], 0),
      sourceMaximumHorizontalOffset
    )
  }
  return movedSelection
    ? (current: aligned, target: nil)
    : (current: current, target: aligned)
}

@MainActor
public final class OverviewController: NSObject {

  public typealias WindowHandler = @MainActor @Sendable (
    WindowID, String, MonitorID, WorkspaceID
  ) -> Void
  public typealias WorkspaceHandler = @MainActor @Sendable (
    MonitorID, WorkspaceID
  ) -> Void
  public typealias DropHandler = @MainActor @Sendable (
    WindowID, String, MonitorID, WorkspaceID, OverviewDropTarget
  ) -> Void
  public typealias MonitorHandler = @MainActor @Sendable (MonitorID) -> Void
  public typealias OpenStateHandler = @MainActor @Sendable (Bool) -> Void
  public typealias ScrollCommitHandler = @MainActor @Sendable (
    [MonitorID: [WorkspaceID: Double]]
  ) -> Void

  private let focusWindowHandler: WindowHandler
  private let focusWorkspaceHandler: WorkspaceHandler
  private let dropHandler: DropHandler
  private let layoutCommandHandler: @MainActor @Sendable (Command, WindowID, String, MonitorID, WorkspaceID, UInt64) -> Void
  private let activateMonitorHandler: MonitorHandler
  private let presentationChanged: @MainActor @Sendable () -> Void
  private var idlePreparationRetry: Task<Void, Never>?
  private let idlePreparationRequested: @MainActor @Sendable () -> Void
  private let openStateHandler: OpenStateHandler
  private let scrollCommitHandler: ScrollCommitHandler
  private var panels: [MonitorID: OverviewPanel] = [:]
  private var snapshot: OverviewSnapshot?
  private var layout = LayoutSettings()
  private var borderStyle = WindowBorderStyle(config: BordersConfig())
  private var viewports: [MonitorID: OverviewViewport] = [:]
  private var projections: [MonitorID: OverviewProjection] = [:]
  private var previewMonitorIDs: [WindowID: MonitorID] = [:]
  private var selectionsByWorkspace: [WorkspaceID: OverviewSelection] = [:]
  private var selection: OverviewSelection?
  private var hasDeferredSelection = false
  private var selectionCommitPending = false
  private var selectionAlignmentFinished = false
  private var selectionNativeReady = false
  private let notificationCenter: NotificationCenter
  private let waitsForNativeSelectionCommit: Bool
  private var drag: OverviewDrag?
  private var edgeScrollTimer: Timer?
  private var edgeScrollDirection: Double?
  public private(set) var sessionGeneration: UInt64 = 0
  private var windowPreviewsEnabled = false
  private var surfaceTransitionsEnabled = false
  private var ribbonRepresentationsEnabled = false
  private var ribbonCornerRadius: Double = 12
  private let surfaceCapture = OverviewSurfaceCapture.shared
  private var surfaceWindowIDs = Set<WindowID>()
  public private(set) var surfaceTransitionCount = 0
  public private(set) var surfaceFallbackCount = 0
  public private(set) var previewClosingCount = 0
  public private(set) var surfaceAcquireMs: Double = 0
  private var openingEvents: [String] = []
  public var openingTransitionHistory: String { openingEvents.isEmpty ? "none" : openingEvents.joined(separator: "|") }
  public var surfaceCaptureState: String { surfaceCapture.state }
  public var ribbonSurfaceTransitions: Int { ExperimentalRibbonRenderer.shared.transitions }
  public var ribbonSurfaceFallbacks: Int { ExperimentalRibbonRenderer.shared.fallbacks }
  public var ribbonSurfaceFallbackReason: String { ExperimentalRibbonRenderer.shared.lastFallback }
  public var ribbonSurfacePresenting: Bool { ExperimentalRibbonRenderer.shared.isPresenting }
  public var surfaceStreamCount: Int { surfaceCapture.streamCount }
  var surfacePresentedFrameCount: Int { panels.values.reduce(0) { $0 + $1.surfacePresentedFrameCount } }
  public var surfaceEstimatedPoolBytes: Int { surfaceCapture.estimatedPoolBytes }
  private var idlePreparationEnabled = true
  private var isUnderMemoryPressure = false
  private var previewTask: Task<Void, Never>?
  private var desktopCaptureRetryTask: Task<Void, Never>?
  private var previewCache: [WindowID: NSImage] = [:]
  private let rememberedPreviews = OverviewPreviewCache()
  private var idlePreviewTask: Task<Void, Never>?
  private var idlePreviewAttempted: [OverviewPreviewRequest] = []
  private var idlePreviewPriorityIDs: Set<WindowID> = []
  private var previewRevealStartedAt: [WindowID: TimeInterval] = [:]
  private var previewCacheExpiry: DispatchWorkItem?
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var attemptedPreviewWindowIDs = Set<WindowID>()
  private var capturedDesktopMonitorIDs = Set<MonitorID>()
  private var hasRequestedPreviewPermission = false
  private var previewPendingCount = 0
  private var alignSelectionOnNextUpdate = false
  private var animationsEnabled = true
  private var overviewZoom = 0.5
  private var windowCornerRadius = 12.0
  private var viewportAnimations: [MonitorID: OverviewViewportAnimation] = [:]
  private var projectionAnimations: [MonitorID: OverviewProjectionAnimation] = [:]
  private var lastRenderedRefresh: [MonitorID: TimeInterval] = [:]
  private var renderedIntervals = 0
  private var renderedIntervalSeconds: TimeInterval = 0
  private var maximumRenderedGap: TimeInterval = 0
  private var lateRenderedRefreshes = 0
  private var renderedFrames = 0
  private var renderedSeconds: TimeInterval = 0
  public var renderPerformance: String {
    let hz = renderedIntervalSeconds > 0 ? Double(renderedIntervals) / renderedIntervalSeconds : 0
    let drawMS = renderedFrames > 0 ? renderedSeconds * 1_000 / Double(renderedFrames) : 0
    return String(format: "%.1fHz/frames:%d/late:%d/maxGapMs:%.2f/meanFrameMs:%.2f",
      hz, renderedFrames, lateRenderedRefreshes, maximumRenderedGap * 1_000, drawMS)
  }
  private var viewportDisplayLinks: [MonitorID: CADisplayLink] = [:]
  private var pendingViewportFrames = Set<MonitorID>()
  private var displayLinkMonitorIDs: [ObjectIdentifier: MonitorID] = [:]

  public var scrollOffsets: [MonitorID: [WorkspaceID: Double]] { viewports.mapValues(\.horizontalOffsets) }
  private var nativeExitCanZoom = true
  public private(set) var isOpen = false
  private var ribbonPrototype = false
  public var usesRibbonPrototype: Bool { ribbonPrototype }
  public private(set) var usesWorkspaceParking = false
  public var panelCount: Int { isOpen ? panels.count : 0 }
  public var retainedPanelCount: Int { panels.count }
  public private(set) var previewPermissionState: OverviewPreviewPermissionState = .disabled
  public private(set) var previewFailureCount = 0
  private var openedAt: TimeInterval = 0
  // Milliseconds from open to the first and latest captured preview of the current session.
  public private(set) var firstPreviewMs: Double?
  public private(set) var lastPreviewMs: Double?
  public private(set) var receivedPreviewCount = 0
  public var previewCacheCount: Int { previewCache.count }
  public var rememberedPreviewMemoryBytes: Int {
    rememberedPreviews.byteCount
  }
  public var inFlightPreviewCount: Int {
    previewTask == nil ? 0 : min(previewPendingCount, overviewPreviewMaximumConcurrentCaptures)
  }

  public init(
    focusWindow: @escaping WindowHandler,
    focusWorkspace: @escaping WorkspaceHandler,
    drop: @escaping DropHandler,
    activateMonitor: @escaping MonitorHandler,
    openStateChanged: @escaping OpenStateHandler,
    presentationChanged: @escaping @MainActor @Sendable () -> Void = {},
    idlePreparationRequested: @escaping @MainActor @Sendable () -> Void = {},
    waitsForNativeSelectionCommit: Bool = false,
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    layoutCommand: @escaping @MainActor @Sendable (Command, WindowID, String, MonitorID, WorkspaceID, UInt64) -> Void = { _, _, _, _, _, _ in },
    commitScrollOffsets: @escaping ScrollCommitHandler
  ) {
    focusWindowHandler = focusWindow
    focusWorkspaceHandler = focusWorkspace
    dropHandler = drop
    layoutCommandHandler = layoutCommand
    activateMonitorHandler = activateMonitor
    openStateHandler = openStateChanged
    self.presentationChanged = presentationChanged
    self.idlePreparationRequested = idlePreparationRequested
    self.waitsForNativeSelectionCommit = waitsForNativeSelectionCommit
    self.notificationCenter = notificationCenter
    scrollCommitHandler = commitScrollOffsets
    super.init()
    let pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main
    )
    pressure.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self, let events = self.memoryPressureSource?.data else { return }
        self.handleMemoryPressure(events)
      }
    }
    pressure.resume()
    memoryPressureSource = pressure
    let center = notificationCenter
    for name in [
      NSWorkspace.screensDidSleepNotification,
      NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.willSleepNotification,
    ] {
      center.addObserver(
        self,
        selector: #selector(closeForSystemTransition(_:)),
        name: name,
        object: nil
      )
    }
  }

  func handleMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
    if events.contains(.critical) || events.contains(.warning) {
      isUnderMemoryPressure = true
      idlePreviewTask?.cancel()
      idlePreviewTask = nil
      idlePreviewAttempted = []
      if events.contains(.critical) { rememberedPreviews.removeAll() }
      else { rememberedPreviews.retain(idlePreviewPriorityIDs, maximumBytes: 4 * 1_024 * 1_024) }
      ExperimentalRibbonRenderer.shared.disable()
      surfaceCapture.stop(state: "pressure")
      idlePreparationEnabled = false
      if !isOpen {
        releaseIdleOverviewResources()
        closePanelsImmediately()
      }
      overviewOpeningLogger.notice("memory-pressure critical=\(events.contains(.critical), privacy: .public) retainedBytes=\(self.rememberedPreviews.byteCount, privacy: .public)")
      presentationChanged()
    } else if events.contains(.normal), isUnderMemoryPressure {
      isUnderMemoryPressure = false
      idlePreparationEnabled = true
      idlePreviewAttempted = []
      overviewOpeningLogger.notice("memory-pressure recovered; requesting idle preparation")
      idlePreparationRequested()
    }
  }

  isolated deinit {
    idlePreviewTask?.cancel()
    desktopCaptureRetryTask?.cancel()
    previewCacheExpiry?.cancel()
    memoryPressureSource?.cancel()
    for link in viewportDisplayLinks.values { link.invalidate() }
    notificationCenter.removeObserver(self)
  }

  public func toggle(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool = false,
    experimentalSurfaceTransitions: Bool = false,
    ribbonPrototype: Bool = false
  ) {
    if isOpen {
      close()
    } else {
      // Explicit renderer experiment: never request a new capture permission.
      guard !ribbonPrototype || CGPreflightScreenCaptureAccess() else { return }
      self.ribbonPrototype = ribbonPrototype
      open(
        snapshot: snapshot,
        layout: layout,
        borders: borders,
        animation: animation,
        zoom: ribbonPrototype ? 1 : zoom,
        windowCornerRadius: windowCornerRadius,
        windowPreviewsEnabled: ribbonPrototype || windowPreviewsEnabled,
        experimentalSurfaceTransitions: experimentalSurfaceTransitions
      )
    }
  }

  public func prepare(
    windowPreviewsEnabled: Bool,
    snapshot: OverviewSnapshot? = nil,
    layout: LayoutSettings = LayoutSettings(),
    zoom: Double = 0.5,
    experimentalSurfaceTransitions: Bool = false,
    experimentalRibbonRepresentations: Bool = false,
    windowCornerRadius: Double = 12
  ) {
    defer { presentationChanged() }
    // A closing zoom still owns its texture; idle refresh must wait for its handoff.
    guard !isOpen, idlePreparationEnabled else { return }
    if panels.values.contains(where: \.hasSurfaceScene) || ExperimentalRibbonRenderer.shared.isPresenting {
      if idlePreparationRetry == nil {
        idlePreparationRetry = Task { [weak self] in
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          guard let self else { return }
          idlePreparationRetry = nil
          if !isOpen { idlePreparationRequested() }
        }
      }
      return
    }
    idlePreparationRetry?.cancel(); idlePreparationRetry = nil
    usesWorkspaceParking = overviewUsesWorkspaceParking(
      windowPreviewsEnabled: windowPreviewsEnabled,
      screenCaptureAccessGranted: windowPreviewsEnabled && CGPreflightScreenCaptureAccess()
    )
    self.windowPreviewsEnabled = windowPreviewsEnabled
    let monitorIDs = Set(NSScreen.screens.compactMap { screen in
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        .map { MonitorID(rawValue: $0.uint64Value) }
    })
    preparePanels(monitorIDs: monitorIDs)
    surfaceTransitionsEnabled = experimentalSurfaceTransitions && windowPreviewsEnabled
    ribbonRepresentationsEnabled = experimentalRibbonRepresentations
    ribbonCornerRadius = windowCornerRadius
    let preparesSurfaces = surfaceTransitionsEnabled || ribbonRepresentationsEnabled
    if !preparesSurfaces { ExperimentalRibbonRenderer.shared.disable() }
    let requests = snapshot.map { surfaceRequests(snapshot: $0, layout: layout, zoom: zoom) } ?? []
    surfaceCapture.prepare(requests, enabled: preparesSurfaces)
    if surfaceTransitionsEnabled, let snapshot {
      prepareIdlePreviews(snapshot: snapshot, layout: layout, zoom: zoom)
    } else {
      idlePreviewTask?.cancel(); idlePreviewTask = nil; idlePreviewAttempted = []
    }
  }

  private func preparePanels(monitorIDs: Set<MonitorID>) {
    let canReusePanels = Set(panels.keys) == monitorIDs
      && panels.allSatisfy { monitorID, panel in
        screen(for: monitorID)?.frame == panel.window.frame
          && panel.usesCapturedDesktop == !usesWorkspaceParking
      }
    guard !canReusePanels else { return }
    closePanelsImmediately()
    for monitorID in monitorIDs {
      guard let screen = screen(for: monitorID) else { continue }
      let panel = OverviewPanel(
        monitorID: monitorID, screen: screen,
        usesCapturedDesktop: !usesWorkspaceParking, delegate: self
      )
      panel.openingTransitionChanged = { [weak self] event in
        self?.recordOpeningTransition(event, monitorID: monitorID)
      }
      panels[monitorID] = panel
      if panel.usesCapturedDesktop { panel.loadWallpaperIfNeeded() }
    }
  }

  public func open(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool = false,
    experimentalSurfaceTransitions: Bool = false
  ) {
    idlePreparationEnabled = !isUnderMemoryPressure
    idlePreparationRetry?.cancel(); idlePreparationRetry = nil
    sessionGeneration &+= 1
    self.snapshot = snapshot
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    previewCacheExpiry?.cancel()
    previewCacheExpiry = nil
    animationsEnabled = animation.enabled
    overviewZoom = ribbonPrototype ? 1 : zoom
    self.windowCornerRadius = windowCornerRadius
    self.windowPreviewsEnabled = windowPreviewsEnabled
    surfaceTransitionsEnabled = experimentalSurfaceTransitions && windowPreviewsEnabled
    usesWorkspaceParking = overviewUsesWorkspaceParking(
      windowPreviewsEnabled: windowPreviewsEnabled,
      screenCaptureAccessGranted: CGPreflightScreenCaptureAccess()
    )
    preparePanels(monitorIDs: Set(snapshot.monitors.map(\.id)))
    for panel in panels.values {
      panel.window.title = ribbonPrototype ? "Defi Ribbon Prototype" : "Defi Overview"
    }
    previewTask?.cancel()
    previewTask = nil
    cancelDesktopCaptureRetry()
    previewCache.removeAll(keepingCapacity: true)
    surfaceWindowIDs.removeAll()
    restoreRememberedPreviews(for: snapshot)
    if surfaceTransitionsEnabled { surfaceCapture.freeze() }
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
    capturedDesktopMonitorIDs.removeAll(keepingCapacity: true)
    previewPendingCount = 0
    previewPermissionState = windowPreviewsEnabled ? .notDetermined : .disabled
    selection = initialSelection(in: snapshot)
    selectionsByWorkspace.removeAll(keepingCapacity: true)
    if let selection { selectionsByWorkspace[selection.location.workspaceID] = selection }
    hasDeferredSelection = false
    selectionCommitPending = false
    nativeExitCanZoom = true
    lastRenderedRefresh.removeAll(keepingCapacity: true)
    renderedIntervals = 0
    renderedIntervalSeconds = 0
    maximumRenderedGap = 0
    lateRenderedRefreshes = 0
    renderedFrames = 0
    renderedSeconds = 0
    viewports = Dictionary(uniqueKeysWithValues: snapshot.monitors.map { monitor in
      (
        monitor.id,
        OverviewViewport(
          horizontalOffsets: Dictionary(
            uniqueKeysWithValues: monitor.workspaces.map {
              ($0.id, $0.scrollOffset)
            }
          )
        )
      )
    })
    isOpen = true
    openedAt = CACurrentMediaTime()
    firstPreviewMs = nil
    lastPreviewMs = nil
    receivedPreviewCount = 0
    if surfaceTransitionsEnabled {
      for (monitorID, panel) in panels {
        if let background = ExperimentalRibbonRenderer.shared.backgroundImage(for: monitorID) {
          panel.setDesktopImage(NSImage(cgImage: background, size: panel.window.frame.size))
        }
      }
    }
    updatePanels(scheduleCaptures: false)
    var surfacesByMonitor: [MonitorID: [WindowID: OverviewSurfaceFrame]] = [:]
    for monitor in snapshot.monitors {
      if let frames = currentSurfaceFrames(snapshot: snapshot, monitorID: monitor.id) {
        surfacesByMonitor[monitor.id] = frames
      }
    }
    openStateHandler(true)
    let fadeDuration = animationsEnabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? overviewOpenFadeDuration : 0
    for (monitorID, panel) in panels {
      let surfaceFrames = surfacesByMonitor[monitorID]
      if surfaceTransitionsEnabled, animationsEnabled, !usesWorkspaceParking,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        let projection = projections[monitorID],
        let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
        let screen = screen(for: monitorID),
        let scene = OverviewSurfaceScene(projection: projection,
          workspaceID: monitor.activeWorkspace, screen: screen, surfaces: surfaceFrames ?? [:],
          windows: snapshot.windows, cornerRadius: windowCornerRadius, previews: previewCache)
      {
        let ids = Set(scene.nativeFrames.keys)
        let capturedIDs = Set(surfaceFrames?.keys.map { $0 } ?? [])
        surfaceWindowIDs.formUnion(capturedIDs)
        attemptedPreviewWindowIDs.formUnion(capturedIDs)
        panel.showSurfaceScene(scene, windowIDs: ids, duration: 0.22)
        surfaceTransitionCount += 1
      } else {
        if surfaceTransitionsEnabled { surfaceFallbackCount += 1 }
        recordOpeningTransition("fallback(enabled:\(surfaceTransitionsEnabled),animation:\(animationsEnabled),parking:\(usesWorkspaceParking),reduceMotion:\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),surfaces:\(surfaceFrames?.count ?? 0),previews:\(previewCache.count))", monitorID: monitorID)
        panel.show(fadeDuration: fadeDuration)
      }
    }
    schedulePreviewsIfNeeded()
  }

  private func recordOpeningTransition(_ event: String, monitorID: MonitorID) {
    let elapsed = max(Int((CACurrentMediaTime() - openedAt) * 1_000), 0)
    let entry = "session:\(sessionGeneration),monitor:\(monitorID.rawValue),ms:\(elapsed),\(event)"
    openingEvents.append(entry)
    if openingEvents.count > 8 { openingEvents.removeFirst(openingEvents.count - 8) }
    overviewOpeningLogger.notice("\(entry, privacy: .public)")
    presentationChanged()
  }

  public func update(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool? = nil,
    experimentalSurfaceTransitions: Bool? = nil
  ) {
    guard isOpen else { return }
    if let experimentalSurfaceTransitions {
      surfaceTransitionsEnabled = experimentalSurfaceTransitions
        && (windowPreviewsEnabled ?? self.windowPreviewsEnabled)
    }
    let previousSnapshot = self.snapshot
    let previousProjections = projections
    let windowPreviewsEnabled = ribbonPrototype ? true : windowPreviewsEnabled
    if let windowPreviewsEnabled,
      self.windowPreviewsEnabled != windowPreviewsEnabled
    {
      self.windowPreviewsEnabled = windowPreviewsEnabled
      previewTask?.cancel()
      previewTask = nil
      cancelDesktopCaptureRetry()
      previewCache.removeAll(keepingCapacity: true)
      if windowPreviewsEnabled {
        restoreRememberedPreviews(for: snapshot)
      } else {
        rememberedPreviews.removeAll()
      }
      resetPreviewFadeAnimation()
      attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
      previewPendingCount = 0
      previewPermissionState = windowPreviewsEnabled ? .notDetermined : .disabled
    }
    self.snapshot = snapshot
    selectionsByWorkspace = selectionsByWorkspace.filter { $0.value.isValid(in: snapshot) }
    pruneRememberedPreviews(for: snapshot)
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    animationsEnabled = animation.enabled
    overviewZoom = ribbonPrototype ? 1 : zoom
    self.windowCornerRadius = windowCornerRadius
    var movedSelectionPositions: (
      previous: OverviewTiledPosition,
      next: OverviewTiledPosition
    )?
    if drag == nil && !ribbonPrototype, !hasDeferredSelection || selection?.isValid(in: snapshot) != true {
      hasDeferredSelection = false
      let focusedSelection = initialSelection(in: snapshot)
      if focusedSelection != selection {
        selection = focusedSelection
        if let focusedSelection { selectionsByWorkspace[focusedSelection.location.workspaceID] = focusedSelection }
        alignSelectionOnNextUpdate = true
      } else if let windowID = selection?.windowID,
        let previousPosition = previousSnapshot?.tiledPosition(of: windowID),
        let nextPosition = snapshot.tiledPosition(of: windowID),
        previousPosition != nextPosition
      {
        alignSelectionOnNextUpdate = true
        movedSelectionPositions = (previousPosition, nextPosition)
      }
    } else if let drag,
      snapshot.windows[drag.windowID]?.appID != drag.appID
        || snapshot.location(of: drag.windowID)
          != OverviewLocation(
            monitorID: drag.sourceMonitorID,
            workspaceID: drag.sourceWorkspaceID
          )
    {
      self.drag = nil
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
    }
    var viewportTargets: [MonitorID: OverviewViewport] = [:]
    if drag == nil, let windowID = selection?.windowID,
      let previousPosition = previousSnapshot?.tiledPosition(of: windowID),
      let nextPosition = snapshot.tiledPosition(of: windowID), previousPosition != nextPosition {
      movedSelectionPositions = (previousPosition, nextPosition)
      alignSelectionOnNextUpdate = true
    }
    for monitor in snapshot.monitors {
      let previousMonitor = previousSnapshot?.monitors.first { $0.id == monitor.id }
      if viewports[monitor.id] == nil {
        viewports[monitor.id] = OverviewViewport()
      }
      for workspace in monitor.workspaces
      where viewports[monitor.id]?.horizontalOffsets[workspace.id] == nil {
        viewports[monitor.id]?.horizontalOffsets[workspace.id] = workspace.scrollOffset
      }
      if let previousWorkspaceID = previousMonitor?.activeWorkspace,
        previousWorkspaceID != monitor.activeWorkspace,
        let previousIndex = monitor.workspaces.firstIndex(where: {
          $0.id == previousWorkspaceID
        }),
        let activeIndex = monitor.workspaces.firstIndex(where: {
          $0.id == monitor.activeWorkspace
        }),
        var viewport = viewports[monitor.id]
      {
        let rebase = Double(previousIndex - activeIndex)
        viewport.workspaceOffset += rebase
        viewports[monitor.id] = viewport
        if let animation = viewportAnimations[monitor.id],
          abs(animation.to.workspaceOffset + rebase) < 0.000_001 {
          // Matching activation changes the origin, not the visual timeline.
          var from = animation.from, to = animation.to
          from.workspaceOffset += rebase
          to.workspaceOffset += rebase
          viewportAnimations[monitor.id] = OverviewViewportAnimation(
            from: from, to: to, startedAt: animation.startedAt, duration: animation.duration)
          viewportTargets[monitor.id] = to
        } else {
          cancelAnimations(on: monitor.id)
          viewport.workspaceOffset = 0
          viewportTargets[monitor.id] = viewport
        }
      }
      guard let previousMonitor else { continue }
      for workspace in monitor.workspaces {
        guard let previousWorkspace = previousMonitor.workspaces.first(where: {
          $0.id == workspace.id
        }),
          previousWorkspace.targetScrollOffset != workspace.targetScrollOffset
        else { continue }
        var target = viewportTargets[monitor.id]
          ?? viewports[monitor.id]
          ?? OverviewViewport()
        target.horizontalOffsets[workspace.id] = workspace.targetScrollOffset
        viewportTargets[monitor.id] = target
      }
    }
    if alignSelectionOnNextUpdate,
      let location = selection?.location,
      let monitor = snapshot.monitors.first(where: {
        $0.id == location.monitorID
      }),
      let workspace = monitor.workspaces.first(where: {
        $0.id == location.workspaceID
      })
    {
      let movedSelection = movedSelectionPositions?.next.monitorID == location.monitorID
      let sourceWorkspaceID = movedSelectionPositions?.previous.monitorID == location.monitorID
        ? movedSelectionPositions?.previous.workspaceID
        : nil
      let transition = overviewViewportTransitionAfterSelectionAlignment(
        current: viewports[location.monitorID] ?? OverviewViewport(),
        pendingTarget: viewportTargets[location.monitorID],
        animationTarget: viewportAnimations[location.monitorID]?.to,
        workspaceID: location.workspaceID,
        scrollOffset: workspace.targetScrollOffset,
        sourceWorkspaceID: sourceWorkspaceID,
        sourceMaximumHorizontalOffset: sourceWorkspaceID.flatMap {
          maximumHorizontalOffset(for: $0, on: monitor)
        },
        movedSelection: movedSelection
      )
      if movedSelection {
        cancelAnimations(on: location.monitorID)
      }
      viewports[location.monitorID] = transition.current
      viewportTargets[location.monitorID] = transition.target
      alignSelectionOnNextUpdate = false
    }
    let monitorIDs = Set(snapshot.monitors.map(\.id))
    guard Set(panels.keys) == monitorIDs,
      snapshot.monitors.allSatisfy({ screen(for: $0.id) != nil })
    else {
      close()
      return
    }
    if let selection, !selection.isValid(in: snapshot) {
      self.selection = initialSelection(in: snapshot)
      drag = nil
    }
    for (monitorID, viewport) in viewportTargets {
      animateViewport(on: monitorID, to: viewport)
    }
    for (monitorID, panel) in panels {
      guard let source = previousProjections[monitorID] else { continue }
      let resizesCards = overviewProjectionResizesExistingCards(
        from: source, to: projection(for: panel, snapshot: snapshot)
      )
      let reordersCards = overviewProjectionReordersExistingCards(
        from: source, to: projection(for: panel, snapshot: snapshot)
      )
      if resizesCards || reordersCards {
        // Size and position changes use one projection timeline.
        if let viewportAnimation = viewportAnimations.removeValue(forKey: monitorID) {
          viewports[monitorID] = viewportAnimation.to
        }
      }
      if resizesCards || reordersCards || movedSelectionPositions?.next.monitorID == monitorID {
        animateProjection(on: monitorID, from: source)
      }
    }
    updatePanels()
  }

  public func close() {
    close(commitScrollOffsets: !ribbonPrototype)
  }

  /// Called after the final native layout has settled underneath the overview.
  public func selectionCommitCompleted(sessionGeneration generation: UInt64? = nil, nativeFramesReady: Bool = true) {
    guard generation == nil || generation == sessionGeneration,
      isOpen, selectionCommitPending else { return }
    selectionNativeReady = true
    nativeExitCanZoom = nativeFramesReady
    finishSelectionCloseIfReady()
  }

  private func finishSelectionCloseIfReady() {
    guard selectionCommitPending, selectionNativeReady, selectionAlignmentFinished else { return }
    close(commitScrollOffsets: false)
  }

  private func close(commitScrollOffsets: Bool) {
    guard isOpen else { return }
    let closingPreviews = previewCache
    let closingProjections = projections
    isOpen = false
    hasDeferredSelection = false
    selectionCommitPending = false
    ribbonPrototype = false
    previewCacheExpiry?.cancel()
    let expiry = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isOpen else { return }
        self.releaseIdleOverviewResources()
        self.previewCacheExpiry = nil
      }
    }
    previewCacheExpiry = expiry
    // Retain textures only through the closing handoff, not for a minute afterward.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: expiry)
    sessionGeneration &+= 1
    edgeScrollTimer?.invalidate()
    edgeScrollTimer = nil
    edgeScrollDirection = nil
    drag = nil
    alignSelectionOnNextUpdate = false
    previewTask?.cancel()
    previewTask = nil
    cancelDesktopCaptureRetry()
    previewCache.removeAll(keepingCapacity: true)
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
    capturedDesktopMonitorIDs.removeAll(keepingCapacity: true)
    previewPendingCount = 0
    stopOverviewAnimations()
    if commitScrollOffsets {
      scrollCommitHandler(viewports.mapValues(\.horizontalOffsets))
    }
    openStateHandler(false)
    let closingPanels = Array(panels.values)
    // Selection already commits focus/layout through the daemon. Whether this
    // close commits viewport offsets must not disable a safe visual handoff.
    let canZoomBack = nativeExitCanZoom && animationsEnabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      && snapshot?.monitors.allSatisfy({ monitor in
        let viewport = viewports[monitor.id] ?? OverviewViewport()
        return viewport.workspaceOffset == 0 && monitor.workspaces.allSatisfy {
          viewport.horizontalOffsets[$0.id, default: $0.scrollOffset] == $0.scrollOffset
        }
      }) == true
    for panel in closingPanels {
      if canZoomBack && panel.hideSurfaceSceneIfUnchanged(duration: 0.22) { continue }
      if nativeExitCanZoom, surfaceTransitionsEnabled, animationsEnabled, !usesWorkspaceParking,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        let snapshot, let monitor = snapshot.monitors.first(where: { $0.id == panel.monitorID }),
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.floatingWindows.isEmpty,
        let viewport = snapshot.monitorFrames[monitor.id], let screen = screen(for: monitor.id),
        let projection = closingProjections[monitor.id],
        let scene = OverviewPreviewClosingScene(projection: projection,
          workspaceID: workspace.id, screen: screen, previews: closingPreviews,
          cornerRadius: windowCornerRadius,
          targets: computeLayout(workspace: workspace, viewport: viewport,
            windows: Array(snapshot.windows.values), settings: layout), windows: snapshot.windows)
      {
        panel.hidePreviewScene(scene, duration: 0.22)
        previewClosingCount += 1
      } else {
        panel.hide()
      }
    }
  }

  public func handleKey(_ action: OverviewKeyAction) {
    guard isOpen else { return }
    if ribbonPrototype {
      if action == .cancel { close(); return }
      guard action == .left || action == .right, let snapshot,
        let monitor = snapshot.monitors.first(where: { $0.id == snapshot.activeMonitorID }) ?? snapshot.monitors.first,
        let panel = panels[monitor.id]
      else { return }
      overviewView(panel.view, pageWorkspace: monitor.activeWorkspace,
                   direction: action == .left ? -1 : 1)
      return
    }
    guard !selectionCommitPending || action == .cancel else { return }
    switch action {
    case .cancel:
      close()
    case .select:
      chooseSelection()
    case .left, .right, .up, .down, .firstColumn, .lastColumn, .workspaceUp, .workspaceDown, .workspace:
      navigate(action)
    case .moveUp, .moveDown:
      moveSelectionVertically(action)
    case .layout(let command):
      _ = applyLayoutCommand(command)
    }
  }

  @discardableResult
  public func applyLayoutCommand(_ command: Command,
    handler: (@MainActor @Sendable (Command, WindowID, String, MonitorID, WorkspaceID, UInt64) -> Void)? = nil
  ) -> Bool {
    guard isOpen, !ribbonPrototype, !selectionCommitPending, let snapshot, let selection,
      let windowID = selection.windowID, let window = snapshot.windows[windowID],
      !snapshot.nativeFullscreenWindowIDs.contains(windowID), window.transientOwnerID == nil,
      !window.floating || command == .toggleFloating else { return false }
    hasDeferredSelection = true
    (handler ?? layoutCommandHandler)(command, windowID, window.appID, selection.location.monitorID,
      selection.location.workspaceID, sessionGeneration)
    return true
  }

  @objc private func closeForSystemTransition(_ notification: Notification) {
    close()
  }

  private func chooseSelection() {
    guard !selectionCommitPending, let snapshot, let selection else { return }
    selectionCommitPending = true
    hasDeferredSelection = false
    selectionAlignmentFinished = false
    selectionNativeReady = !waitsForNativeSelectionCommit
    alignSelectionOnNextUpdate = true
    guard focusSelection(selection, in: snapshot) else {
      selectionCommitPending = false
      close(commitScrollOffsets: true)
      return
    }
    closeAfterSelectionAlignment()
  }

  private func focusSelection(_ selection: OverviewSelection, in snapshot: OverviewSnapshot) -> Bool {
    switch selection {
    case .window(let windowID, let monitorID, let workspaceID):
      guard let window = snapshot.windows[windowID] else { return false }
      focusWindowHandler(windowID, window.appID, monitorID, workspaceID)
    case .workspace(let monitorID, let workspaceID):
      focusWorkspaceHandler(monitorID, workspaceID)
    }
    return true
  }

  private func closeAfterSelectionAlignment() {
    guard animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      selectionAlignmentFinished = true
      finishSelectionCloseIfReady()
      return
    }
    let generation = sessionGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + overviewTransitionDuration) {
      [weak self] in
      guard let self, isOpen, sessionGeneration == generation else { return }
      selectionAlignmentFinished = true
      finishSelectionCloseIfReady()
    }
  }

  private func navigate(_ action: OverviewKeyAction) {
    guard !selectionCommitPending, let snapshot,
      let target = navigationTarget(
        from: selection ?? initialSelection(in: snapshot),
        action: action,
        snapshot: snapshot
      ), target != selection
    else { return }
    selection = target
    selectionsByWorkspace[target.location.workspaceID] = target
    hasDeferredSelection = true
    guard let monitor = snapshot.monitors.first(where: { $0.id == target.location.monitorID }),
      let activeIndex = monitor.workspaces.firstIndex(where: { $0.id == monitor.activeWorkspace }),
      let targetIndex = monitor.workspaces.firstIndex(where: { $0.id == target.location.workspaceID })
    else { return }
    var viewport = viewportAnimations[monitor.id]?.to ?? viewports[monitor.id] ?? OverviewViewport()
    viewport.workspaceOffset = Double(targetIndex - activeIndex)
    if let windowID = target.windowID, let frame = snapshot.monitorFrames[monitor.id] {
      var workspace = monitor.workspaces[targetIndex]
      if let column = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) }) {
        workspace.focusedColumn = column
        viewport.horizontalOffsets[workspace.id] = focusedColumnLeftScrollOffset(
          workspace: workspace, viewport: frame, windows: Array(snapshot.windows.values), settings: layout)
      }
    }
    animateViewport(on: monitor.id, to: viewport)
    updatePanels()
  }

  private func moveSelectionVertically(_ action: OverviewKeyAction) {
    guard !selectionCommitPending else { return }
    guard let snapshot,
      case .window(let windowID, let monitorID, let workspaceID) = selection,
      let window = snapshot.windows[windowID],
      window.transientOwnerID == nil,
      snapshot.nativeFullscreenWindowIDs.contains(windowID) == false,
      let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
      let workspaceIndex = monitor.workspaces.firstIndex(where: {
        $0.id == workspaceID
      })
    else { return }
    let workspace = monitor.workspaces[workspaceIndex]
    let delta = action == .moveUp ? -1 : 1
    let target: OverviewDropTarget
    if let columnIndex = workspace.columns.firstIndex(where: {
      $0.windows.contains(windowID)
    }),
      let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID),
      workspace.columns[columnIndex].windows.indices.contains(windowIndex + delta)
    {
      target = .stack(
        monitorID: monitorID,
        workspaceID: workspaceID,
        columnIndex: columnIndex,
        windowIndex: delta < 0 ? windowIndex - 1 : windowIndex + 2
      )
    } else {
      let targetWorkspaceIndex = workspaceIndex + delta
      guard monitor.workspaces.indices.contains(targetWorkspaceIndex) else { return }
      let targetWorkspace = monitor.workspaces[targetWorkspaceIndex]
      if let columnIndex = workspace.columns.firstIndex(where: {
        $0.windows.contains(windowID)
      }) {
        target = .newColumn(
          monitorID: monitorID,
          workspaceID: targetWorkspace.id,
          columnIndex: min(columnIndex, targetWorkspace.columns.count)
        )
      } else {
        guard workspace.floatingWindows.contains(windowID),
          let monitorFrame = snapshot.monitorFrames[monitorID],
          let frame = snapshot.floatingFrames[windowID],
          monitorFrame.width > 0,
          monitorFrame.height > 0
        else { return }
        target = .floating(
          monitorID: monitorID,
          workspaceID: targetWorkspace.id,
          relativeFrame: Rect(
            x: (frame.x - monitorFrame.x) / monitorFrame.width,
            y: (frame.y - monitorFrame.y) / monitorFrame.height,
            width: frame.width / monitorFrame.width,
            height: frame.height / monitorFrame.height
          )
        )
      }
    }
    commitOverviewDrop(
      windowID: windowID,
      appID: window.appID,
      sourceMonitorID: monitorID,
      sourceWorkspaceID: workspaceID,
      target: target
    )
  }

  private func navigationTarget(
    from selection: OverviewSelection?,
    action: OverviewKeyAction,
    snapshot: OverviewSnapshot
  ) -> OverviewSelection? {
    guard let selection else { return initialSelection(in: snapshot) }
    let location = selection.location
    guard let monitor = snapshot.monitors.first(where: { $0.id == location.monitorID }),
      let workspaceIndex = monitor.workspaces.firstIndex(where: {
        $0.id == location.workspaceID
      })
    else { return initialSelection(in: snapshot) }
    let workspace = monitor.workspaces[workspaceIndex]

    switch action {
    case .workspace(let target):
      let destination: (Monitor, Workspace)?
      switch target {
      case .named(let name):
        destination = snapshot.monitors.compactMap { candidate in
          candidate.workspaces.first(where: { $0.id.rawValue == name }).map { (candidate, $0) }
        }.first
      case .position(let position):
        destination = position > 0 && !monitor.workspaces.isEmpty
          ? (monitor, monitor.workspaces[min(position - 1, monitor.workspaces.count - 1)]) : nil
      case .relative:
        destination = nil
      }
      guard let (destinationMonitor, destinationWorkspace) = destination else { return selection }
      if let remembered = selectionsByWorkspace[destinationWorkspace.id],
        remembered.windowID != nil, remembered.isValid(in: snapshot) {
        return remembered
      }
      return firstSelection(in: destinationWorkspace, monitorID: destinationMonitor.id)
        ?? .workspace(monitorID: destinationMonitor.id, workspaceID: destinationWorkspace.id)
    case .left, .right:
      let delta = action == .left ? -1 : 1
      if case .window(let windowID, _, _) = selection,
        let columnIndex = workspace.columns.firstIndex(where: {
          $0.windows.contains(windowID)
        })
      {
        let targetColumnIndex = columnIndex + delta
        guard workspace.columns.indices.contains(targetColumnIndex) else { return selection }
        let targetColumn = workspace.columns[targetColumnIndex]
        guard !targetColumn.windows.isEmpty else { return selection }
        let sourceWindowIndex = workspace.columns[columnIndex].windows.firstIndex(
          of: windowID
        ) ?? 0
        let targetWindowID = targetColumn.windows[
          min(sourceWindowIndex, targetColumn.windows.count - 1)
        ]
        return .window(
          windowID: targetWindowID,
          monitorID: monitor.id,
          workspaceID: workspace.id
        )
      }
      return firstSelection(in: workspace, monitorID: monitor.id) ?? selection
    case .firstColumn, .lastColumn:
      guard let column = action == .firstColumn ? workspace.columns.first : workspace.columns.last,
        column.windows.indices.contains(column.focusedWindow) else { return selection }
      return .window(windowID: column.windows[column.focusedWindow],
        monitorID: monitor.id, workspaceID: workspace.id)
    case .up, .down, .workspaceUp, .workspaceDown:
      let delta = action == .up || action == .workspaceUp ? -1 : 1
      if action == .up || action == .down, case .window(let windowID, _, _) = selection,
        let columnIndex = workspace.columns.firstIndex(where: {
          $0.windows.contains(windowID)
        }),
        let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID)
      {
        let targetWindowIndex = windowIndex + delta
        if workspace.columns[columnIndex].windows.indices.contains(targetWindowIndex) {
          return .window(
            windowID: workspace.columns[columnIndex].windows[targetWindowIndex],
            monitorID: monitor.id,
            workspaceID: workspace.id
          )
        }
      }
      let adjacentIndex = workspaceIndex + delta
      guard monitor.workspaces.indices.contains(adjacentIndex) else { return selection }
      let adjacent = monitor.workspaces[adjacentIndex]
      if let remembered = selectionsByWorkspace[adjacent.id],
        remembered.location.monitorID == monitor.id, remembered.isValid(in: snapshot) {
        return remembered
      }
      return firstSelection(
        in: adjacent,
        monitorID: monitor.id
      ) ?? .workspace(
        monitorID: monitor.id,
        workspaceID: monitor.workspaces[adjacentIndex].id
      )
    case .moveUp, .moveDown, .select, .cancel, .layout:
      return selection
    }
  }

  private func firstSelection(
    in workspace: Workspace,
    monitorID: MonitorID
  ) -> OverviewSelection? {
    if workspace.focusedLayer == .floating,
      workspace.floatingWindows.indices.contains(workspace.focusedFloatingWindow)
    {
      return .window(
        windowID: workspace.floatingWindows[workspace.focusedFloatingWindow],
        monitorID: monitorID,
        workspaceID: workspace.id
      )
    }
    if workspace.columns.indices.contains(workspace.focusedColumn) {
      let column = workspace.columns[workspace.focusedColumn]
      if column.windows.indices.contains(column.focusedWindow) {
        return .window(
          windowID: column.windows[column.focusedWindow],
          monitorID: monitorID,
          workspaceID: workspace.id
        )
      }
    }
    if let windowID = workspace.columns.first?.windows.first
      ?? workspace.floatingWindows.first
    {
      return .window(
        windowID: windowID,
        monitorID: monitorID,
        workspaceID: workspace.id
      )
    }
    return nil
  }

  private func initialSelection(in snapshot: OverviewSnapshot) -> OverviewSelection? {
    guard let monitor = snapshot.activeMonitorID.flatMap({ activeID in
      snapshot.monitors.first(where: { $0.id == activeID })
    }) ?? snapshot.monitors.first,
      let workspace = monitor.workspaces.first(where: {
        $0.id == monitor.activeWorkspace
      })
    else { return nil }
    return firstSelection(in: workspace, monitorID: monitor.id)
      ?? .workspace(monitorID: monitor.id, workspaceID: workspace.id)
  }

  private func updatePanels(
    scheduleCaptures: Bool = true,
    only requestedMonitorID: MonitorID? = nil
  ) {
    guard let snapshot else { return }
    var projections = self.projections.filter { panels[$0.key] != nil }
    let now = CACurrentMediaTime()
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let previewOpacities = Dictionary(
      uniqueKeysWithValues: previewCache.keys.map { windowID in
        (
          windowID,
          overviewPreviewOpacity(
            startedAt: previewRevealStartedAt[windowID],
            now: now,
            reduceMotion: reduceMotion
          )
        )
      }
    )
    for (monitorID, panel) in panels
    where requestedMonitorID == nil || requestedMonitorID == monitorID {
      let target = projection(for: panel, snapshot: snapshot)
      let invalidated = panel.invalidateSurfaceScene(ifProjectionChanged: target)
      surfaceWindowIDs.subtract(invalidated)
      attemptedPreviewWindowIDs.subtract(invalidated)
      let projection = displayedProjection(
        target: target,
        on: monitorID,
        now: now,
        reduceMotion: reduceMotion
      )
      projections[monitorID] = projection
      panel.view.surfaceWindowIDs = surfaceWindowIDs
      panel.view.update(
        snapshot: snapshot,
        projection: projection,
        selection: selection,
        drag: drag?.presentation(on: monitorID, panel: panel),
        borderStyle: borderStyle,
        windowCornerRadius: windowCornerRadius,
        previews: previewCache,
        previewOpacities: previewOpacities
      )
    }
    self.projections = projections
    previewMonitorIDs.removeAll(keepingCapacity: true)
    for (monitorID, projection) in projections {
      for card in projection.workspaces.flatMap(\.windows) {
        previewMonitorIDs[card.windowID] = monitorID
      }
    }
    if scheduleCaptures { schedulePreviewsIfNeeded() }
  }

  private func projection(
    for panel: OverviewPanel,
    snapshot: OverviewSnapshot
  ) -> OverviewProjection {
    projectOverview(
      snapshot: snapshot,
      monitorID: panel.monitorID,
      bounds: Rect(
        x: 0,
        y: 0,
        width: panel.view.bounds.width,
        height: panel.view.bounds.height
      ),
      viewport: viewports[panel.monitorID] ?? OverviewViewport(),
      layout: layout,
      zoom: overviewZoom
    )
  }

  private func displayedProjection(
    target: OverviewProjection,
    on monitorID: MonitorID,
    now: TimeInterval,
    reduceMotion: Bool
  ) -> OverviewProjection {
    guard animationsEnabled, !reduceMotion,
      let animation = projectionAnimations[monitorID]
    else {
      projectionAnimations[monitorID] = nil
      return target
    }
    let elapsed = now - animation.startedAt
    guard elapsed < animation.duration else {
      projectionAnimations[monitorID] = nil
      return target
    }
    return interpolateOverviewProjection(
      from: animation.from,
      to: animation.to,
      progress: animatedScalar(
        from: 0,
        to: 1,
        elapsed: elapsed,
        duration: animation.duration
      ),
      foregroundWindowID: selection?.windowID
    )
  }

  private func schedulePreviewsIfNeeded() {
    guard windowPreviewsEnabled, isOpen, previewTask == nil,
      previewPermissionState != .denied
    else { return }
    guard let snapshot else { return }
    let requests = visiblePreviewRequests(snapshot: snapshot, projections: projections,
      selection: selection).filter {
      !attemptedPreviewWindowIDs.contains($0.windowID)
    }
    let hasPendingDesktopCapture = panels.keys.contains {
      !capturedDesktopMonitorIDs.contains($0)
    }
    guard overviewCaptureBatchNeeded(
      previewRequestCount: requests.count,
      hasPendingDesktopCapture: hasPendingDesktopCapture
    ) else { return }
    defer { presentationChanged() }
    attemptedPreviewWindowIDs.formUnion(requests.map(\.windowID))
    previewPendingCount = requests.count
    cancelDesktopCaptureRetry()
    let generation = sessionGeneration
    previewTask = Task { @MainActor [weak self] in
      await Task.yield()
      await self?.capturePreviewBatch(
        requests,
        generation: generation
      )
    }
  }

  private func capturePreviewBatch(
    _ requests: [OverviewPreviewRequest],
    generation: UInt64
  ) async {
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    let permissionGranted: Bool
    let screenCaptureAccessGranted = CGPreflightScreenCaptureAccess()
    if screenCaptureAccessGranted {
      permissionGranted = true
    } else {
      guard overviewShouldRequestCapturePermission(
        screenCaptureAccessGranted: screenCaptureAccessGranted,
        ribbonPrototype: ribbonPrototype,
        hasRequestedPermission: hasRequestedPreviewPermission
      ) else {
        permissionGranted = false
        previewPermissionState = .denied
        finishPreviewBatch(generation: generation)
        return
      }
      hasRequestedPreviewPermission = true
      permissionGranted = await Task.detached(priority: .userInitiated) {
        CGRequestScreenCaptureAccess()
      }.value
    }
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    previewPermissionState = permissionGranted ? .granted : .denied
    guard permissionGranted, !Task.isCancelled else {
      finishPreviewBatch(generation: generation)
      return
    }

    let desktopRequests = desktopCaptureRequests()
    let results = await captureOverviewImages(
      previews: requests,
      desktops: desktopRequests,
      previewCompleted: { [weak self] result in
        self?.receivePreview(result, generation: generation)
      }
    )
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled
    else {
      finishPreviewBatch(generation: generation)
      return
    }
    capturedDesktopMonitorIDs = overviewRecordedDesktopCaptureMonitorIDs(
      existing: capturedDesktopMonitorIDs,
      requested: Set(desktopRequests.map(\.monitorID)),
      captured: Set(results.desktops.keys)
    )
    let shouldRetryDesktopCapture = overviewDesktopCaptureRetryNeeded(
      requested: Set(desktopRequests.map(\.monitorID)),
      captured: Set(results.desktops.keys)
    )
    for (monitorID, image) in results.desktops {
      panels[monitorID]?.setDesktopImage(
        NSImage(cgImage: image, size: panels[monitorID]?.window.frame.size ?? .zero),
        fadeDuration: animationsEnabled
          && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
          ? overviewDesktopFadeDuration : 0
      )
    }
    finishPreviewBatch(generation: generation)
    if results.authorizationDeclined {
      previewPermissionState = .denied
      cancelDesktopCaptureRetry()
    }
    if shouldRetryDesktopCapture && !results.authorizationDeclined {
      scheduleDesktopCaptureRetry(generation: generation)
    }
    updatePanels(scheduleCaptures: false)
  }

  private func receivePreview(_ result: OverviewPreviewCaptureResult, generation: UInt64) {
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration,
      !Task.isCancelled else { return }
    previewPendingCount = max(previewPendingCount - 1, 0)
    defer { presentationChanged() }
    guard let monitorID = snapshot?.monitors.first(where: { monitor in
      monitor.workspaces.contains { workspace in
        workspace.columns.contains { $0.windows.contains(result.request.windowID) }
          || workspace.floatingWindows.contains(result.request.windowID)
      }
    })?.id,
      snapshot?.windows[result.request.windowID]?.appID == result.request.expectedAppID
    else {
      previewFailureCount += 1
      return
    }
    guard let image = result.image, image.width > 1, image.height > 1 else {
      previewCache[result.request.windowID] = nil
      rememberedPreviews.remove(result.request.windowID)
      previewFailureCount += 1
      return
    }
    let elapsedMs = (CACurrentMediaTime() - openedAt) * 1_000
    firstPreviewMs = firstPreviewMs ?? elapsedMs
    lastPreviewMs = elapsedMs
    receivedPreviewCount += 1
    let preview = NSImage(
      cgImage: image,
      size: NSSize(width: result.request.width, height: result.request.height)
    )
    previewCache[result.request.windowID] = preview
    if let window = snapshot?.windows[result.request.windowID],
      let rememberedImage = result.rememberedImage
    {
      rememberedPreviews.store(
        NSImage(cgImage: rememberedImage, size: preview.size),
        byteCost: rememberedImage.bytesPerRow * rememberedImage.height,
        for: window
      )
    }
    // Offscreen captures are ready before navigation, without running an idle fade link.
    guard previewMonitorIDs[result.request.windowID] != nil else { return }
    // A replaced preview cross-fades from the remembered image instead of swapping.
    if previewRevealStartedAt[result.request.windowID] == nil {
      previewRevealStartedAt[result.request.windowID] = CACurrentMediaTime()
    }
    // Always start the link: a window moved to another monitor mid-fade needs that monitor's link.
    startPreviewFadeAnimation(on: monitorID)
    panels[monitorID]?.view.updatePreview(preview, for: result.request.windowID,
      opacity: overviewPreviewOpacity(startedAt: previewRevealStartedAt[result.request.windowID],
        now: CACurrentMediaTime(), reduceMotion: !animationsEnabled
          || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
  }

  private func finishPreviewBatch(generation: UInt64) {
    guard generation == sessionGeneration else { return }
    previewTask = nil
    previewPendingCount = 0
    presentationChanged()
  }

  private func scheduleDesktopCaptureRetry(generation: UInt64) {
    cancelDesktopCaptureRetry()
    desktopCaptureRetryTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(1))
      } catch {
        return
      }
      guard let self else { return }
      self.desktopCaptureRetryTask = nil
      guard self.windowPreviewsEnabled, self.isOpen,
        generation == self.sessionGeneration
      else { return }
      self.schedulePreviewsIfNeeded()
    }
  }

  private func cancelDesktopCaptureRetry() {
    desktopCaptureRetryTask?.cancel()
    desktopCaptureRetryTask = nil
  }

  private func startPreviewFadeAnimation(on monitorID: MonitorID) {
    guard animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    else {
      resetPreviewFadeAnimation()
      return
    }
    guard let link = displayLink(on: monitorID) else {
      if let projection = projections[monitorID] {
        for card in projection.workspaces.flatMap(\.windows) {
          previewRevealStartedAt[card.windowID] = nil
        }
      }
      return
    }
    link.isPaused = false
  }

  private func resetPreviewFadeAnimation() {
    previewRevealStartedAt.removeAll(keepingCapacity: true)
  }

  private func updatePreviewFade(on monitorID: MonitorID) -> Bool {
    guard let projection = projections[monitorID] else { return false }
    let now = CACurrentMediaTime()
    let reduceMotion = !animationsEnabled
      || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var opacities: [WindowID: Double] = [:]
    var pending = false
    for card in projection.workspaces.flatMap(\.windows) {
      let opacity = overviewPreviewOpacity(
        startedAt: previewRevealStartedAt[card.windowID],
        now: now, reduceMotion: reduceMotion
      )
      opacities[card.windowID] = opacity
      if opacity < 1 {
        pending = true
      } else {
        previewRevealStartedAt[card.windowID] = nil
      }
    }
    panels[monitorID]?.view.updatePreviewOpacities(opacities)
    return pending
  }

  private func restoreRememberedPreviews(for snapshot: OverviewSnapshot) {
    guard windowPreviewsEnabled, CGPreflightScreenCaptureAccess() else {
      rememberedPreviews.removeAll()
      return
    }
    pruneRememberedPreviews(for: snapshot)
    previewCache.merge(rememberedPreviews.images) { _, remembered in remembered }
  }

  private func pruneRememberedPreviews(for snapshot: OverviewSnapshot) {
    for windowID in rememberedPreviews.prune(windows: snapshot.windows) {
      previewCache[windowID] = nil
    }
  }

  func releaseIdleOverviewResources() {
    guard !isOpen else { return }
    defer { presentationChanged() }
    // Expiry may beat a delayed closing-animation continuation. Hiding first
    // prevents cancellation from leaving an input-blocking panel on screen.
    for panel in panels.values { panel.hide() }
    snapshot = nil
    projections.removeAll()
  }

  // One-shot compact previews reuse the existing bounded cache. No inactive streams.
  private func prepareIdlePreviews(snapshot: OverviewSnapshot, layout: LayoutSettings, zoom: Double) {
    guard CGPreflightScreenCaptureAccess() else { return }
    idlePreviewPriorityIDs = Set(snapshot.monitors.compactMap { monitor in
      monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace })
        .flatMap { firstSelection(in: $0, monitorID: monitor.id)?.windowID }
    })
    pruneRememberedPreviews(for: snapshot)
    let projections = panels.mapValues { panel in
      projectOverview(snapshot: snapshot, monitorID: panel.monitorID,
        bounds: Rect(x: 0, y: 0, width: panel.view.bounds.width, height: panel.view.bounds.height),
        viewport: OverviewViewport(), layout: layout, zoom: zoom, includeOffscreenContent: true)
    }
    let requests = visiblePreviewRequests(snapshot: snapshot, projections: projections,
      selection: initialSelection(in: snapshot)).map { request in
        let (width, height) = overviewPreviewPixelSize(cardWidth: Double(request.width),
          cardHeight: Double(request.height), scale: 1, maximumWidth: 512, maximumHeight: 512)
        return OverviewPreviewRequest(windowID: request.windowID, expectedAppID: request.expectedAppID,
          width: width, height: height,
          blurFadeHeight: max(Int(Double(request.blurFadeHeight) * Double(height) / Double(request.height)), 1))
      }
    guard requests != idlePreviewAttempted else { return }
    idlePreviewAttempted = requests
    idlePreviewTask?.cancel()
    let missing = requests.filter { rememberedPreviews.images[$0.windowID] == nil }
    guard !missing.isEmpty else { idlePreviewTask = nil; return }
    idlePreviewTask = Task { [weak self] in
      _ = await captureOverviewImages(previews: missing, desktops: [], previewCompleted: { result in
        guard let self, !Task.isCancelled, let image = result.rememberedImage,
          let window = snapshot.windows[result.request.windowID] else { return }
        self.rememberedPreviews.store(NSImage(cgImage: image,
          size: NSSize(width: result.request.width, height: result.request.height)),
          byteCost: image.bytesPerRow * image.height, for: window)
      })
    }
  }

  private func visiblePreviewRequests(snapshot: OverviewSnapshot,
    projections: [MonitorID: OverviewProjection], selection: OverviewSelection?
  ) -> [OverviewPreviewRequest] {
    var candidates: [OverviewPreviewCandidate] = []
    var anchor: (x: Double, y: Double)?
    for (monitorID, projection) in projections {
      let scale = max(panels[monitorID]?.window.backingScaleFactor ?? 1, 1)
      for card in projection.workspaces.flatMap(\.windows) {
        guard let window = snapshot.windows[card.windowID] else { continue }
        let (width, height) = overviewPreviewPixelSize(
          cardWidth: card.frame.width, cardHeight: card.frame.height, scale: scale
        )
        let titleBandHeight = overviewWindowTitleBandHeight(
          iconSize: overviewWindowTitleIconSize(cardHeight: card.frame.height)
        )
        let centerX = card.frame.x + card.frame.width / 2
        let centerY = card.frame.y + card.frame.height / 2
        if card.windowID == selection?.windowID { anchor = (centerX, centerY) }
        candidates.append(OverviewPreviewCandidate(
          request: OverviewPreviewRequest(
            windowID: card.windowID,
            expectedAppID: window.appID,
            width: width,
            height: height,
            blurFadeHeight: Int(
              overviewPreviewBlurFadeHeight(
                titleBandHeight: titleBandHeight,
                imageScale: CGFloat(height) / card.frame.height,
                imageHeight: CGFloat(height)
              ).rounded(.up)
            )
          ),
          monitorID: monitorID, centerX: centerX, centerY: centerY
        ))
      }
    }
    return boundedOverviewPreviewRequests(overviewPreviewCaptureOrder(
      candidates, selectedMonitorID: selection?.location.monitorID, anchor: anchor
    ))
  }

  private func surfaceRequests(
    snapshot: OverviewSnapshot, layout: LayoutSettings, zoom: Double
  ) -> [OverviewSurfaceRequest] {
    ExperimentalRibbonRenderer.shared.prepare(snapshot: snapshot, layout: layout,
      enabled: surfaceTransitionsEnabled || ribbonRepresentationsEnabled,
      cornerRadius: ribbonCornerRadius, preloadWorkspace: ribbonRepresentationsEnabled)
    return ExperimentalRibbonRenderer.shared.requests
  }

  private func currentSurfaceFrames(snapshot: OverviewSnapshot, monitorID: MonitorID) -> [WindowID: OverviewSurfaceFrame]? {
    guard surfaceTransitionsEnabled, animationsEnabled, !usesWorkspaceParking,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return nil }
    ExperimentalRibbonRenderer.shared.cancel()
    let projected = Set(projections[monitorID]?.workspaces.first(where: {
      $0.workspaceID == snapshot.monitors.first(where: { $0.id == monitorID })?.activeWorkspace
    })?.windows.map(\.windowID) ?? [])
    let ids = projected.intersection(ExperimentalRibbonRenderer.shared.capturedIDs(on: monitorID))
    let start = CACurrentMediaTime()
    let frames = surfaceCapture.availableFrames(windowIDs: ids)
    surfaceAcquireMs = (CACurrentMediaTime() - start) * 1_000
    return frames
  }

  private func desktopCaptureRequests() -> [OverviewDesktopCaptureRequest] {
    panels.compactMap { monitorID, panel in
      guard !capturedDesktopMonitorIDs.contains(monitorID),
        let displayID = CGDirectDisplayID(exactly: monitorID.rawValue)
      else { return nil }
      return OverviewDesktopCaptureRequest(
        monitorID: monitorID,
        displayID: displayID,
        width: max(Int(panel.window.frame.width.rounded(.up)), 1),
        height: max(Int(panel.window.frame.height.rounded(.up)), 1)
      )
    }
  }

  private func screen(for monitorID: MonitorID) -> NSScreen? {
    NSScreen.screens.first { screen in
      (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? NSNumber)?.uint64Value == monitorID.rawValue
    }
  }

  private func animateViewport(
    on monitorID: MonitorID,
    to target: OverviewViewport
  ) {
    let current = viewports[monitorID] ?? target
    guard viewportAnimations[monitorID]?.to != target else { return }
    if current == target {
      if viewportAnimations[monitorID] != nil {
        cancelAnimations(on: monitorID)
        updatePanels()
      }
      return
    }
    guard animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let link = displayLink(on: monitorID)
    else {
      cancelAnimations(on: monitorID)
      viewports[monitorID] = target
      updatePanels()
      return
    }
    viewportAnimations[monitorID] = OverviewViewportAnimation(
      from: current,
      to: target,
      startedAt: CACurrentMediaTime(),
      duration: overviewTransitionDuration
    )
    projectionAnimations[monitorID] = nil
    link.isPaused = false
  }

  private func animateProjection(
    on monitorID: MonitorID,
    from source: OverviewProjection?
  ) {
    guard let source, let snapshot, let panel = panels[monitorID] else { return }
    let target = projection(for: panel, snapshot: snapshot)
    guard projectionAnimations[monitorID]?.to != target else { return }
    guard source != target,
      animationsEnabled,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let link = displayLink(on: monitorID)
    else {
      projectionAnimations[monitorID] = nil
      return
    }
    projectionAnimations[monitorID] = OverviewProjectionAnimation(
      from: source,
      to: target,
      startedAt: CACurrentMediaTime(),
      duration: overviewTransitionDuration
    )
    link.isPaused = false
  }

  private func displayLink(on monitorID: MonitorID) -> CADisplayLink? {
    if let existing = viewportDisplayLinks[monitorID] { return existing }
    guard let screen = screen(for: monitorID) else { return nil }
    let link = screen.displayLink(
      target: self,
      selector: #selector(viewportDisplayLinkDidFire(_:))
    )
    let refreshRate = Float(max(screen.maximumFramesPerSecond, 1))
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: refreshRate, maximum: refreshRate, preferred: refreshRate)
    link.add(to: .main, forMode: .common)
    viewportDisplayLinks[monitorID] = link
    displayLinkMonitorIDs[ObjectIdentifier(link)] = monitorID
    return link
  }

  private func requestViewportFrame(on monitorID: MonitorID) {
    guard let link = displayLink(on: monitorID) else {
      updatePanels(only: monitorID)
      return
    }
    // Keep every precise delta, but render only the latest accumulated viewport
    // once per refresh. The pending flag also submits the final momentum event.
    pendingViewportFrames.insert(monitorID)
    link.isPaused = false
  }

  @objc private func viewportDisplayLinkDidFire(_ link: CADisplayLink) {
    guard let monitorID = displayLinkMonitorIDs[ObjectIdentifier(link)] else {
      link.isPaused = true
      return
    }
    let started = CACurrentMediaTime()
    let view = panels[monitorID]?.view
    let drawsBefore = view?.drawCount ?? 0
    let geometryChanged = pendingViewportFrames.remove(monitorID) != nil
      || viewportAnimations[monitorID] != nil
      || projectionAnimations[monitorID] != nil
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if let animation = viewportAnimations[monitorID] {
      let elapsed = CACurrentMediaTime() - animation.startedAt
      if !animationsEnabled || reduceMotion || elapsed >= animation.duration {
        viewports[monitorID] = animation.to
        viewportAnimations[monitorID] = nil
      } else {
        let progress = animatedScalar(
          from: 0,
          to: 1,
          elapsed: elapsed,
          duration: animation.duration
        )
        viewports[monitorID] = interpolateOverviewViewport(
          from: animation.from,
          to: animation.to,
          progress: progress
        )
      }
    }
    if geometryChanged { updatePanels(only: monitorID) }
    let fadePending = updatePreviewFade(on: monitorID)
    view?.displayIfNeeded()
    if (view?.drawCount ?? 0) > drawsBefore {
      renderedFrames += 1
      renderedSeconds += CACurrentMediaTime() - started
      if let previous = lastRenderedRefresh[monitorID] {
        let gap = started - previous
        renderedIntervals += 1
        renderedIntervalSeconds += gap
        maximumRenderedGap = max(maximumRenderedGap, gap)
        if gap > link.duration * 1.5 { lateRenderedRefreshes += 1 }
      }
      lastRenderedRefresh[monitorID] = started
    }
    if !fadePending, viewportAnimations[monitorID] == nil,
      projectionAnimations[monitorID] == nil
    {
      link.isPaused = true
      lastRenderedRefresh[monitorID] = nil
      presentationChanged()
    }
  }

  private func cancelAnimations(on monitorID: MonitorID) {
    viewportAnimations[monitorID] = nil
    projectionAnimations[monitorID] = nil
    viewportDisplayLinks[monitorID]?.isPaused = !updatePreviewFade(on: monitorID)
    if viewportDisplayLinks[monitorID]?.isPaused == true { lastRenderedRefresh[monitorID] = nil }
  }

  private func stopOverviewAnimations() {
    lastRenderedRefresh.removeAll(keepingCapacity: true)
    pendingViewportFrames.removeAll(keepingCapacity: true)
    viewportAnimations.removeAll(keepingCapacity: true)
    projectionAnimations.removeAll(keepingCapacity: true)
    for link in viewportDisplayLinks.values { link.invalidate() }
    viewportDisplayLinks.removeAll(keepingCapacity: true)
    displayLinkMonitorIDs.removeAll(keepingCapacity: true)
  }

  private func closePanelsImmediately() {
    // Panel recreation must preserve the warmed window surfaces for the opening handoff.
    // Capture lifetime is controlled by prepare() and memory pressure independently.
    stopOverviewAnimations()
    for panel in panels.values { panel.close() }
    panels.removeAll(keepingCapacity: true)
    isOpen = false
  }

  private func panelAndPoint(at screenPoint: NSPoint) -> (OverviewPanel, OverviewPoint)? {
    for panel in panels.values where panel.window.frame.contains(screenPoint) {
      let point = panel.localPoint(fromScreen: screenPoint)
      return (panel, OverviewPoint(x: point.x, y: point.y))
    }
    return nil
  }

  private func maximumHorizontalOffset(
    for workspaceID: WorkspaceID,
    on monitor: Monitor
  ) -> Double? {
    guard let snapshot,
      let monitorFrame = snapshot.monitorFrames[monitor.id],
      var workspace = monitor.workspaces.first(where: { $0.id == workspaceID })
    else { return nil }
    workspace.focusedColumn = max(workspace.columns.count - 1, 0)
    return focusedColumnLeftScrollOffset(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: monitorFrame.width, height: monitorFrame.height),
      windows: Array(snapshot.windows.values),
      settings: layout
    )
  }
}

@MainActor
extension OverviewController: OverviewViewDelegate {
  func overviewView(
    _ view: OverviewView,
    clickedAt point: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard isOpen, !selectionCommitPending, !ribbonPrototype else { return }
    guard let projection = projections[view.monitorID],
      let hit = projection.hitTest(OverviewPoint(x: point.x, y: point.y)),
      let snapshot
    else { return }
    activateMonitorHandler(view.monitorID)
    switch hit {
    case .window(let windowID, let monitorID, let workspaceID):
      guard snapshot.windows[windowID] != nil else { return }
      selection = .window(windowID: windowID, monitorID: monitorID, workspaceID: workspaceID)
    case .workspace(let monitorID, let workspaceID):
      selection = .workspace(monitorID: monitorID, workspaceID: workspaceID)
    }
    if let selection { selectionsByWorkspace[selection.location.workspaceID] = selection }
    chooseSelection()
  }

  func overviewView(
    _ view: OverviewView,
    beganDragging windowID: WindowID,
    at screenPoint: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard isOpen, !selectionCommitPending, !ribbonPrototype else { return }
    guard let snapshot,
      let window = snapshot.windows[windowID],
      let location = snapshot.location(of: windowID),
      let sourceProjection = projections[view.monitorID],
      let sourceCard = sourceProjection.workspaces.flatMap(\.windows).first(
        where: { $0.windowID == windowID && $0.canDrag }
      )
    else { return }
    cancelAnimations(on: view.monitorID)
    drag = OverviewDrag(
      windowID: windowID,
      appID: window.appID,
      sourceMonitorID: location.monitorID,
      sourceWorkspaceID: location.workspaceID,
      screenPoint: screenPoint,
      cardSize: NSSize(width: sourceCard.frame.width, height: sourceCard.frame.height),
      target: nil,
      targetMonitorID: nil
    )
    updateDrag(at: screenPoint)
  }

  func overviewView(
    _ view: OverviewView,
    draggedTo screenPoint: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    updateDrag(at: screenPoint)
  }

  func overviewView(
    _ view: OverviewView,
    endedDraggingAt screenPoint: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard let drag else { return }
    edgeScrollTimer?.invalidate()
    edgeScrollTimer = nil
    self.drag = nil
    updatePanels()
    guard let target = drag.target else { return }
    commitOverviewDrop(
      windowID: drag.windowID,
      appID: drag.appID,
      sourceMonitorID: drag.sourceMonitorID,
      sourceWorkspaceID: drag.sourceWorkspaceID,
      target: target
    )
  }

  func overviewView(
    _ view: OverviewView,
    scrolled delta: NSPoint,
    hasPreciseScrollingDeltas: Bool,
    at point: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID })
    else { return }
    activateMonitorHandler(view.monitorID)
    let scrollAxis = overviewScrollAxis(for: delta)
    let workspaceID = scrollAxis == .horizontal
      ? projections[view.monitorID]?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      )?.workspaceID
      : nil
    let activeIndex = monitor.workspaces.firstIndex(where: {
      $0.id == monitor.activeWorkspace
    }) ?? 0
    let viewport: OverviewViewport
    if hasPreciseScrollingDeltas {
      cancelAnimations(on: view.monitorID)
      viewport = viewports[view.monitorID] ?? OverviewViewport()
    } else {
      viewport = viewportAnimations[view.monitorID]?.to
        ?? viewports[view.monitorID]
        ?? OverviewViewport()
    }
    let target = overviewViewportAfterScroll(
      viewport,
      delta: delta,
      hasPreciseScrollingDeltas: hasPreciseScrollingDeltas,
      viewSize: view.bounds.size,
      zoom: overviewZoom,
      activeWorkspaceIndex: activeIndex,
      workspaceCount: monitor.workspaces.count,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: workspaceID.flatMap {
        maximumHorizontalOffset(for: $0, on: monitor)
      }
    )
    if hasPreciseScrollingDeltas {
      guard target != viewport else { return }
      viewports[view.monitorID] = target
      requestViewportFrame(on: view.monitorID)
    } else {
      animateViewport(on: view.monitorID, to: target)
    }
  }

  func overviewView(
    _ view: OverviewView,
    rightDraggedBy deltaX: Double,
    at point: NSPoint
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID }),
      let viewport = viewports[view.monitorID],
      let workspaceID = projections[view.monitorID]?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      )?.workspaceID,
      let maximumOffset = maximumHorizontalOffset(for: workspaceID, on: monitor)
    else { return }
    activateMonitorHandler(view.monitorID)
    cancelAnimations(on: view.monitorID)
    let activeIndex = monitor.workspaces.firstIndex(where: {
      $0.id == monitor.activeWorkspace
    }) ?? 0
    viewports[view.monitorID] = overviewViewportAfterScroll(
      viewport,
      delta: NSPoint(x: deltaX, y: 0),
      hasPreciseScrollingDeltas: true,
      viewSize: view.bounds.size,
      zoom: overviewZoom,
      activeWorkspaceIndex: activeIndex,
      workspaceCount: monitor.workspaces.count,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: maximumOffset
    )
    requestViewportFrame(on: view.monitorID)
  }

  func overviewView(
    _ view: OverviewView,
    pageWorkspace workspaceID: WorkspaceID,
    direction: Int
  ) {
    guard isOpen, !selectionCommitPending else { return }
    guard let snapshot,
      let monitor = snapshot.monitors.first(where: { $0.id == view.monitorID }),
      let maximumOffset = maximumHorizontalOffset(for: workspaceID, on: monitor)
    else { return }
    var viewport = viewportAnimations[view.monitorID]?.to
      ?? viewports[view.monitorID]
      ?? OverviewViewport()
    activateMonitorHandler(view.monitorID)
    let currentOffset = viewport.horizontalOffsets[workspaceID] ?? 0
    viewport.horizontalOffsets[workspaceID] = min(
      max(currentOffset + Double(direction), 0),
      maximumOffset
    )
    animateViewport(on: view.monitorID, to: viewport)
  }

  private func updateDrag(at screenPoint: NSPoint) {
    guard var drag, let snapshot else { return }
    drag.screenPoint = screenPoint
    if let (panel, point) = panelAndPoint(at: screenPoint),
      let projection = projections[panel.monitorID]
    {
      drag.target = overviewDropTarget(
        at: point,
        sourceWindowID: drag.windowID,
        projection: projection,
        snapshot: snapshot
      )
      drag.targetMonitorID = panel.monitorID
      activateEdgeScroll(for: panel, localY: point.y)
    } else {
      drag.target = nil
      drag.targetMonitorID = nil
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
    }
    self.drag = drag
    updatePanels()
  }

  private func commitOverviewDrop(
    windowID: WindowID,
    appID: String,
    sourceMonitorID: MonitorID,
    sourceWorkspaceID: WorkspaceID,
    target: OverviewDropTarget
  ) {
    guard isOpen, !selectionCommitPending else { return }
    let location = target.location
    selection = .window(
      windowID: windowID,
      monitorID: location.monitorID,
      workspaceID: location.workspaceID
    )
    alignSelectionOnNextUpdate = true
    activateMonitorHandler(location.monitorID)
    dropHandler(
      windowID,
      appID,
      sourceMonitorID,
      sourceWorkspaceID,
      target
    )
  }

  private func activateEdgeScroll(for panel: OverviewPanel, localY: Double) {
    let margin = 56.0
    let direction: Double
    if localY < margin {
      direction = -1
    } else if localY > panel.view.bounds.height - margin {
      direction = 1
    } else {
      edgeScrollTimer?.invalidate()
      edgeScrollTimer = nil
      edgeScrollDirection = nil
      return
    }
    if edgeScrollDirection == direction { return }
    edgeScrollTimer?.invalidate()
    edgeScrollDirection = direction
    edgeScrollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.15,
      repeats: true
    ) { [weak self, weak panel] _ in
      MainActor.assumeIsolated {
        guard let self, let panel,
          var viewport = self.viewports[panel.monitorID],
          let monitor = self.snapshot?.monitors.first(where: {
            $0.id == panel.monitorID
          })
        else { return }
        self.cancelAnimations(on: panel.monitorID)
        let activeIndex = monitor.workspaces.firstIndex(where: {
          $0.id == monitor.activeWorkspace
        }) ?? 0
        viewport.workspaceOffset = min(
          max(viewport.workspaceOffset + direction * 0.2, Double(-activeIndex)),
          Double(monitor.workspaces.count - activeIndex - 1)
        )
        self.viewports[panel.monitorID] = viewport
        self.updatePanels()
      }
    }
  }
}

enum OverviewSelection: Equatable {
  case window(windowID: WindowID, monitorID: MonitorID, workspaceID: WorkspaceID)
  case workspace(monitorID: MonitorID, workspaceID: WorkspaceID)

  var location: (monitorID: MonitorID, workspaceID: WorkspaceID) {
    switch self {
    case .window(_, let monitorID, let workspaceID),
      .workspace(let monitorID, let workspaceID):
      (monitorID, workspaceID)
    }
  }

  var windowID: WindowID? {
    if case .window(let windowID, _, _) = self { return windowID }
    return nil
  }

  func isValid(in snapshot: OverviewSnapshot) -> Bool {
    guard let workspace = snapshot.monitors.first(where: {
        $0.id == location.monitorID
      })?.workspaces.first(where: { $0.id == location.workspaceID })
    else { return false }
    switch self {
    case .window(let windowID, _, _):
      return snapshot.windows[windowID] != nil
        && (workspace.columns.contains(where: { $0.windows.contains(windowID) })
          || workspace.floatingWindows.contains(windowID))
    case .workspace:
      return true
    }
  }
}

private struct OverviewLocation: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
}

private struct OverviewTiledPosition: Equatable {
  let monitorID: MonitorID
  let workspaceID: WorkspaceID
  let columnIndex: Int
  let windowIndex: Int
}

private extension OverviewSnapshot {
  func location(of windowID: WindowID) -> OverviewLocation? {
    for monitor in monitors {
      for workspace in monitor.workspaces
      where workspace.columns.contains(where: { $0.windows.contains(windowID) })
        || workspace.floatingWindows.contains(windowID)
      {
        return OverviewLocation(monitorID: monitor.id, workspaceID: workspace.id)
      }
    }
    return nil
  }

  func tiledPosition(of windowID: WindowID) -> OverviewTiledPosition? {
    for monitor in monitors {
      for workspace in monitor.workspaces {
        for (columnIndex, column) in workspace.columns.enumerated() {
          guard let windowIndex = column.windows.firstIndex(of: windowID) else { continue }
          return OverviewTiledPosition(
            monitorID: monitor.id,
            workspaceID: workspace.id,
            columnIndex: columnIndex,
            windowIndex: windowIndex
          )
        }
      }
    }
    return nil
  }
}

private struct OverviewDrag {
  let windowID: WindowID
  let appID: String
  let sourceMonitorID: MonitorID
  let sourceWorkspaceID: WorkspaceID
  var screenPoint: NSPoint
  let cardSize: NSSize
  var target: OverviewDropTarget?
  var targetMonitorID: MonitorID?

  @MainActor
  func presentation(
    on monitorID: MonitorID,
    panel: OverviewPanel
  ) -> OverviewDragPresentation {
    let localPoint = targetMonitorID == monitorID
      ? panel.localPoint(fromScreen: screenPoint)
      : nil
    return OverviewDragPresentation(
      windowID: windowID,
      localPoint: localPoint,
      cardSize: cardSize,
      target: targetMonitorID == monitorID ? target : nil
    )
  }
}

struct OverviewDragPresentation: Equatable {
  let windowID: WindowID
  let localPoint: NSPoint?
  let cardSize: NSSize
  let target: OverviewDropTarget?
}

private extension OverviewHit {
  var workspaceID: WorkspaceID {
    switch self {
    case .window(_, _, let workspaceID), .workspace(_, let workspaceID):
      workspaceID
    }
  }
}

private extension OverviewDropTarget {
  var location: (monitorID: MonitorID, workspaceID: WorkspaceID) {
    switch self {
    case .newColumn(let monitorID, let workspaceID, _),
      .stack(let monitorID, let workspaceID, _, _),
      .floating(let monitorID, let workspaceID, _):
      (monitorID, workspaceID)
    }
  }
}
