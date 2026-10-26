import AppKit
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import QuartzCore

private let overviewOpeningLogger = Logger(subsystem: "com.qeude.defi", category: "OverviewOpening")

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
  hasRequestedPermission: Bool
) -> Bool {
  !screenCaptureAccessGranted && !hasRequestedPermission
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
  private var surfaceWindowIDs = Set<WindowID>()
  public private(set) var surfaceTransitionCount = 0
  public private(set) var surfaceFallbackCount = 0
  public private(set) var previewClosingCount = 0
  private var openingEvents: [String] = []
  public var openingTransitionHistory: String { openingEvents.isEmpty ? "none" : openingEvents.joined(separator: "|") }
  /// The shared window capture cache, as shown by status.
  public var captureCacheDescription: String {
    let store = WindowCaptureStore.shared
    return "pictures:\(store.count),reduced:\(store.reducedCount),compressed:\(store.compressedCount)"
      + ",fullMiB:\(String(format: "%.1f", Double(store.fullByteCount) / 1_048_576))"
      + ",backgroundMiB:\(String(format: "%.1f", Double(store.backgroundByteCount) / 1_048_576))"
  }
  var surfacePresentedFrameCount: Int { panels.values.reduce(0) { $0 + $1.surfacePresentedFrameCount } }
  private var idlePreparationEnabled = true
  private var isUnderMemoryPressure = false
  private var previewTask: Task<Void, Never>?
  // Shared pictures shown this session; the cache owns the memory.
  private var previews: [WindowID: WindowPicture] = [:]
  // Small blurred title-band copies, kept across sessions until their picture changes.
  // Keyed by a non-owning identity: a released picture must not stay resident here.
  private var blurredPreviews: [WindowID: (source: ObjectIdentifier, image: CGImage?)] = [:]
  private var blurTask: Task<Void, Never>?
  private var shownDesktops: [MonitorID: CGImage] = [:]
  // Bounded per session: a failing wallpaper capture is retried on later updates.
  private var desktopRequests = 0
  private static let desktopRequestLimit = 5
  private var capturesObserver: NSObjectProtocol?
  private var previewRevealStartedAt: [WindowID: TimeInterval] = [:]
  private var previewCacheExpiry: DispatchWorkItem?
  private var memoryPressureSource: DispatchSourceMemoryPressure?
  private var attemptedPreviewWindowIDs = Set<WindowID>()
  private var hasRequestedPreviewPermission = false
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
  public private(set) var usesWorkspaceParking = false
  public var panelCount: Int { isOpen ? panels.count : 0 }
  public var retainedPanelCount: Int { panels.count }
  public private(set) var previewPermissionState: OverviewPreviewPermissionState = .disabled
  public var previewFailureCount: Int { WindowCaptureCache.shared.failureCount }
  private var openedAt: TimeInterval = 0
  // Milliseconds from open to the first and latest captured preview of the current session.
  public private(set) var firstPreviewMs: Double?
  public private(set) var lastPreviewMs: Double?
  public private(set) var receivedPreviewCount = 0
  public var previewCacheCount: Int { previews.count }
  public var captureCacheBytes: Int { WindowCaptureStore.shared.byteCount }
  public var inFlightPreviewCount: Int { WindowCaptureCache.shared.isCapturing ? 1 : 0 }

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
    capturesObserver = NotificationCenter.default.addObserver(
      forName: .windowCapturesArrived, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.capturesArrived() }
    }
  }

  func handleMemoryPressure(_ events: DispatchSource.MemoryPressureEvent) {
    if events.contains(.critical) || events.contains(.warning) {
      isUnderMemoryPressure = true
      WindowCaptureStore.shared.applyMemoryPressure(events)
      if events.contains(.critical) { blurredPreviews.removeAll() }
      // An open Overview must not keep pictures the cache just released.
      if isOpen, let snapshot {
        previews = sharedPreviews(for: snapshot)
        updatePanels(scheduleCaptures: false)
      }
      idlePreparationEnabled = !events.contains(.critical)
      if !isOpen {
        releaseIdleOverviewResources()
        closePanelsImmediately()
      }
      overviewOpeningLogger.notice("memory-pressure critical=\(events.contains(.critical), privacy: .public) retainedBytes=\(WindowCaptureStore.shared.byteCount, privacy: .public)")
      presentationChanged()
    } else if events.contains(.normal), isUnderMemoryPressure {
      isUnderMemoryPressure = false
      WindowCaptureStore.shared.applyMemoryPressure(events)
      idlePreparationEnabled = true
      overviewOpeningLogger.notice("memory-pressure recovered; requesting idle preparation")
      idlePreparationRequested()
    }
  }

  isolated deinit {
    blurTask?.cancel()
    previewCacheExpiry?.cancel()
    memoryPressureSource?.cancel()
    for link in viewportDisplayLinks.values { link.invalidate() }
    notificationCenter.removeObserver(self)
    if let capturesObserver { NotificationCenter.default.removeObserver(capturesObserver) }
  }

  public func toggle(
    snapshot: OverviewSnapshot,
    layout: LayoutSettings,
    borders: BordersConfig = BordersConfig(),
    animation: AnimationConfig = AnimationConfig(),
    zoom: Double = 0.5,
    windowCornerRadius: Double = 12,
    windowPreviewsEnabled: Bool = true
  ) {
    if isOpen {
      close()
    } else {
      // Ask before presenting: the overview panel would cover the system prompt.
      // A refusal is remembered for the session; the overview then opens with cards.
      if windowPreviewsEnabled, overviewShouldRequestCapturePermission(
        screenCaptureAccessGranted: CGPreflightScreenCaptureAccess(),
        hasRequestedPermission: hasRequestedPreviewPermission
      ) {
        hasRequestedPreviewPermission = true
        CGRequestScreenCaptureAccess()
        return
      }
      open(
        snapshot: snapshot,
        layout: layout,
        borders: borders,
        animation: animation,
        zoom: zoom,
        windowCornerRadius: windowCornerRadius,
        windowPreviewsEnabled: windowPreviewsEnabled
      )
    }
  }

  public func prepare(
    windowPreviewsEnabled: Bool,
    snapshot: OverviewSnapshot? = nil,
    layout: LayoutSettings = LayoutSettings(),
    zoom: Double = 0.5
  ) {
    defer { presentationChanged() }
    // A closing zoom still owns its texture; idle refresh must wait for its handoff.
    guard !isOpen, idlePreparationEnabled else { return }
    if panels.values.contains(where: \.hasSurfaceScene) {
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
    // Missing pictures only: the opening shows every window without a capture of its own.
    if !usesWorkspaceParking, !isUnderMemoryPressure, let snapshot {
      WindowCaptureCache.shared.refreshForOverview(
        overviewCaptureRequests(snapshot: snapshot, shown: nil),
        displays: monitorIDs.compactMap { CGDirectDisplayID(exactly: $0.rawValue) }, landing: false)
      showSharedDesktops(fadeDuration: 0)
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
    shownDesktops.removeAll()
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
    windowPreviewsEnabled: Bool = true
  ) {
    idlePreparationRetry?.cancel(); idlePreparationRetry = nil
    sessionGeneration &+= 1
    self.snapshot = snapshot
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    previewCacheExpiry?.cancel()
    previewCacheExpiry = nil
    animationsEnabled = animation.enabled
    overviewZoom = zoom
    self.windowCornerRadius = windowCornerRadius
    self.windowPreviewsEnabled = windowPreviewsEnabled
    usesWorkspaceParking = overviewUsesWorkspaceParking(
      windowPreviewsEnabled: windowPreviewsEnabled,
      screenCaptureAccessGranted: CGPreflightScreenCaptureAccess()
    )
    preparePanels(monitorIDs: Set(snapshot.monitors.map(\.id)))
    for panel in panels.values { panel.window.title = "Defi Overview" }
    previewTask?.cancel()
    previewTask = nil
    surfaceWindowIDs.removeAll()
    // Whatever the shared cache holds shows at once; fresher pictures cross-fade in.
    previews = sharedPreviews(for: snapshot)
    blurredPreviews = blurredPreviews.filter { snapshot.windows[$0.key] != nil }
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
    desktopRequests = 0
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
    showSharedDesktops(fadeDuration: 0)
    updatePanels(scheduleCaptures: false)
    deriveBlurs()
    openStateHandler(true)
    let fadeDuration = animationsEnabled
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? overviewOpenFadeDuration : 0
    for (monitorID, panel) in panels {
      if animationsEnabled, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        let projection = projections[monitorID],
        let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
        let screen = screen(for: monitorID),
        let scene = OverviewSurfaceScene(projection: projection,
          workspaceID: monitor.activeWorkspace, screen: screen, pictures: previews,
          windows: snapshot.windows, cornerRadius: windowCornerRadius)
      {
        let ids = Set(scene.nativeFrames.keys)
        // Zoomed with their own fresh picture: no recapture swaps it mid-zoom.
        let capturedIDs = scene.surfaceWindowIDs
        surfaceWindowIDs.formUnion(capturedIDs)
        attemptedPreviewWindowIDs.formUnion(capturedIDs)
        panel.showSurfaceScene(scene, windowIDs: ids, duration: 0.22)
        surfaceTransitionCount += 1
      } else {
        surfaceFallbackCount += 1
        recordOpeningTransition("fallback(animation:\(animationsEnabled),parking:\(usesWorkspaceParking),reduceMotion:\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion),previews:\(previews.count))", monitorID: monitorID)
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
    windowPreviewsEnabled: Bool? = nil
  ) {
    guard isOpen else { return }
    let previousSnapshot = self.snapshot
    let previousProjections = projections
    if let windowPreviewsEnabled,
      self.windowPreviewsEnabled != windowPreviewsEnabled
    {
      self.windowPreviewsEnabled = windowPreviewsEnabled
      previewTask?.cancel()
      previewTask = nil
      previews = sharedPreviews(for: snapshot)
      resetPreviewFadeAnimation()
      attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
      previewPermissionState = windowPreviewsEnabled ? .notDetermined : .disabled
    }
    self.snapshot = snapshot
    selectionsByWorkspace = selectionsByWorkspace.filter { $0.value.isValid(in: snapshot) }
    previews = previews.filter { id, picture in
      snapshot.windows[id].map { $0.processID == picture.processID && $0.appID == picture.appID } == true
    }
    self.layout = layout
    borderStyle = WindowBorderStyle(config: borders)
    animationsEnabled = animation.enabled
    overviewZoom = zoom
    self.windowCornerRadius = windowCornerRadius
    var movedSelectionPositions: (
      previous: OverviewTiledPosition,
      next: OverviewTiledPosition
    )?
    if drag == nil, !hasDeferredSelection || selection?.isValid(in: snapshot) != true {
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
    close(commitScrollOffsets: true)
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
    let closingPreviews = previews
    let closingProjections = projections
    isOpen = false
    hasDeferredSelection = false
    selectionCommitPending = false
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
    previews.removeAll(keepingCapacity: true)
    resetPreviewFadeAnimation()
    attemptedPreviewWindowIDs.removeAll(keepingCapacity: true)
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
      if nativeExitCanZoom, animationsEnabled,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
        let snapshot, let monitor = snapshot.monitors.first(where: { $0.id == panel.monitorID }),
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.floatingWindows.isEmpty,
        let viewport = snapshot.monitorFrames[monitor.id], let screen = screen(for: monitor.id),
        let projection = closingProjections[monitor.id],
        let scene = OverviewPreviewClosingScene(projection: projection,
          workspaceID: workspace.id, screen: screen, previews: closingPreviews,
          wallpaper: panel.view.desktopImage, cornerRadius: windowCornerRadius,
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
    guard !selectionCommitPending || action == .cancel else { return }
    switch action {
    case .cancel:
      close()
    case .select:
      chooseSelection()
    case .left, .right, .up, .down, .firstColumn, .lastColumn, .workspaceUp, .workspaceDown, .workspace,
      .monitor:
      navigate(action)
    case .moveUp, .moveDown:
      moveSelectionVertically(action)
    case .moveToMonitor(let direction):
      moveSelectionToMonitor(direction)
    case .layout(let command):
      _ = applyLayoutCommand(command)
    }
  }

  @discardableResult
  public func applyLayoutCommand(_ command: Command,
    handler: (@MainActor @Sendable (Command, WindowID, String, MonitorID, WorkspaceID, UInt64) -> Void)? = nil
  ) -> Bool {
    guard isOpen, !selectionCommitPending, let snapshot, let selection,
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
    if selection?.location.monitorID != target.location.monitorID {
      activateMonitorHandler(target.location.monitorID)
    }
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
    guard let snapshot, case let (window, monitor, workspace)? = movableSelection(in: snapshot),
      let workspaceIndex = monitor.workspaces.firstIndex(where: { $0.id == workspace.id })
    else { return }
    let windowID = window.id
    let delta = action == .moveUp ? -1 : 1
    let columnIndex = workspace.columns.firstIndex(where: { $0.windows.contains(windowID) })
    if let columnIndex,
      let windowIndex = workspace.columns[columnIndex].windows.firstIndex(of: windowID),
      workspace.columns[columnIndex].windows.indices.contains(windowIndex + delta)
    {
      commitOverviewDrop(
        windowID: windowID,
        appID: window.appID,
        sourceMonitorID: monitor.id,
        sourceWorkspaceID: workspace.id,
        target: .stack(
          monitorID: monitor.id,
          workspaceID: workspace.id,
          columnIndex: columnIndex,
          windowIndex: delta < 0 ? windowIndex - 1 : windowIndex + 2
        )
      )
      return
    }
    guard monitor.workspaces.indices.contains(workspaceIndex + delta) else { return }
    let targetWorkspace = monitor.workspaces[workspaceIndex + delta]
    transferSelection(window, from: (monitor.id, workspace), to: monitor.id,
      workspace: targetWorkspace, columnIndex: min(columnIndex ?? 0, targetWorkspace.columns.count),
      snapshot: snapshot)
  }

  private func moveSelectionToMonitor(_ direction: Direction) {
    guard let snapshot, case let (window, monitor, workspace)? = movableSelection(in: snapshot),
      let targetMonitorID = spatialMonitor(from: monitor.id, toward: direction, frames: snapshot.routingFrames),
      let targetMonitor = snapshot.monitors.first(where: { $0.id == targetMonitorID }),
      let targetWorkspace = displayedWorkspace(on: targetMonitor)
    else { return }
    transferSelection(window, from: (monitor.id, workspace), to: targetMonitorID,
      workspace: targetWorkspace,
      columnIndex: targetWorkspace.columns.isEmpty ? 0 : targetWorkspace.focusedColumn + 1,
      snapshot: snapshot)
  }

  private func movableSelection(in snapshot: OverviewSnapshot) -> (Window, Monitor, Workspace)? {
    guard !selectionCommitPending,
      case .window(let windowID, let monitorID, let workspaceID) = selection,
      let window = snapshot.windows[windowID],
      window.transientOwnerID == nil,
      !snapshot.nativeFullscreenWindowIDs.contains(windowID),
      let monitor = snapshot.monitors.first(where: { $0.id == monitorID }),
      let workspace = monitor.workspaces.first(where: { $0.id == workspaceID })
    else { return nil }
    return (window, monitor, workspace)
  }

  /// Tiled windows open a new column; floating ones keep their place relative to the monitor.
  private func transferSelection(
    _ window: Window,
    from source: (monitorID: MonitorID, workspace: Workspace),
    to monitorID: MonitorID,
    workspace targetWorkspace: Workspace,
    columnIndex: Int,
    snapshot: OverviewSnapshot
  ) {
    let target: OverviewDropTarget
    let windowID = window.id
    if source.workspace.columns.contains(where: { $0.windows.contains(windowID) }) {
      target = .newColumn(monitorID: monitorID, workspaceID: targetWorkspace.id, columnIndex: columnIndex)
    } else {
      guard source.workspace.floatingWindows.contains(windowID),
        let monitorFrame = snapshot.monitorFrames[source.monitorID],
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
    commitOverviewDrop(
      windowID: windowID,
      appID: window.appID,
      sourceMonitorID: source.monitorID,
      sourceWorkspaceID: source.workspace.id,
      target: target
    )
  }

  /// The workspace the overview currently centers on that monitor.
  private func displayedWorkspace(on monitor: Monitor) -> Workspace? {
    guard let activeIndex = monitor.workspaces.firstIndex(where: { $0.id == monitor.activeWorkspace })
    else { return monitor.workspaces.first }
    let offset = (viewportAnimations[monitor.id]?.to ?? viewports[monitor.id])?.workspaceOffset ?? 0
    let index = min(max(activeIndex + Int(offset.rounded()), 0), monitor.workspaces.count - 1)
    return monitor.workspaces[index]
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
    case .monitor(let direction):
      guard let targetID = spatialMonitor(from: monitor.id, toward: direction, frames: snapshot.routingFrames),
        let target = snapshot.monitors.first(where: { $0.id == targetID }),
        let targetWorkspace = displayedWorkspace(on: target)
      else { return selection }
      if let remembered = selectionsByWorkspace[targetWorkspace.id],
        remembered.location.monitorID == targetID, remembered.isValid(in: snapshot) {
        return remembered
      }
      return firstSelection(in: targetWorkspace, monitorID: targetID)
        ?? .workspace(monitorID: targetID, workspaceID: targetWorkspace.id)
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
    case .moveUp, .moveDown, .moveToMonitor, .select, .cancel, .layout:
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
      uniqueKeysWithValues: previews.keys.map { windowID in
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
        previews: previews,
        blurredPreviews: blurredPreviews.compactMapValues(\.image),
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
      previewPermissionState != .denied, let snapshot
    else { return }
    let requests = overviewCaptureRequests(snapshot: snapshot, shown: projections).filter {
      !attemptedPreviewWindowIDs.contains($0.id)
    }
    let displays = desktopRequests >= Self.desktopRequestLimit || usesWorkspaceParking ? [] : panels.keys
      .compactMap { CGDirectDisplayID(exactly: $0.rawValue) }
      .filter { WindowCaptureStore.shared.background($0) == nil }
    guard !requests.isEmpty || !displays.isEmpty else { return }
    defer { presentationChanged() }
    attemptedPreviewWindowIDs.formUnion(requests.map(\.id))
    if !displays.isEmpty { desktopRequests += 1 }
    let generation = sessionGeneration
    previewTask = Task { @MainActor [weak self] in
      await Task.yield()
      await self?.requestCaptures(requests, displays: displays, generation: generation)
    }
  }

  // Permission is asked here, once per session; the shared cache does the capturing.
  private func requestCaptures(_ requests: [RibbonProxyRefresh], displays: [CGDirectDisplayID],
    generation: UInt64) async {
    defer {
      if generation == sessionGeneration { previewTask = nil }
      presentationChanged()
    }
    guard windowPreviewsEnabled, isOpen, generation == sessionGeneration, !Task.isCancelled
    else { return }
    if !CGPreflightScreenCaptureAccess() {
      guard overviewShouldRequestCapturePermission(
        screenCaptureAccessGranted: false,
        hasRequestedPermission: hasRequestedPreviewPermission
      ) else {
        previewPermissionState = .denied
        return
      }
      hasRequestedPreviewPermission = true
      let granted = await Task.detached(priority: .userInitiated) {
        CGRequestScreenCaptureAccess()
      }.value
      guard windowPreviewsEnabled, isOpen, generation == sessionGeneration, !Task.isCancelled
      else { return }
      guard granted else {
        previewPermissionState = .denied
        return
      }
    }
    // A ScreenCaptureKit refusal suspends capture until restart; cards stand in.
    guard await !overviewCaptureLimiter.authorizationDeclined else {
      previewPermissionState = .denied
      return
    }
    previewPermissionState = .granted
    WindowCaptureCache.shared.refreshForOverview(requests, displays: displays, landing: true)
  }

  /// Cards in `shown` projections are refreshed like windows in view; without
  /// projections every window is warmed, unshown, for the next opening.
  private func overviewCaptureRequests(snapshot: OverviewSnapshot,
    shown projections: [MonitorID: OverviewProjection]?) -> [RibbonProxyRefresh] {
    let shown = projections.map { Set($0.values.flatMap { $0.workspaces.flatMap(\.windows).map(\.windowID) }) }
    return snapshot.windows.values.compactMap { window in
      guard let processID = window.processID, shown?.contains(window.id) ?? true else { return nil }
      return RibbonProxyRefresh(id: window.id, appID: window.appID, processID: processID,
        frame: window.frame, distance: shown == nil ? 1 : 0)
    }
  }

  /// The shared pictures of this snapshot's windows, owner-checked.
  private func sharedPreviews(for snapshot: OverviewSnapshot) -> [WindowID: WindowPicture] {
    // Permission, not the parking mode chosen at opening: previews enabled mid-session show.
    guard windowPreviewsEnabled, CGPreflightScreenCaptureAccess() else { return [:] }
    let store = WindowCaptureStore.shared
    return Dictionary(uniqueKeysWithValues: snapshot.windows.compactMap { id, window in
      store.picture(id).flatMap {
        $0.processID == window.processID && $0.appID == window.appID ? (id, $0) : nil
      }
    })
  }

  private func capturesArrived() {
    guard isOpen, windowPreviewsEnabled, let snapshot else { return }
    defer { presentationChanged() }
    let latest = sharedPreviews(for: snapshot)
    let removed = previews.keys.filter { latest[$0] == nil }
    for id in removed { previews[id] = nil }
    let now = CACurrentMediaTime()
    let reduceMotion = !animationsEnabled || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    for (id, picture) in latest where previews[id] != picture {
      let elapsedMs = (now - openedAt) * 1_000
      firstPreviewMs = firstPreviewMs ?? elapsedMs
      lastPreviewMs = elapsedMs
      receivedPreviewCount += 1
      previews[id] = picture
      // Offscreen captures are ready before navigation, without running an idle fade link.
      guard let monitorID = previewMonitorIDs[id] else { continue }
      // A replaced preview cross-fades from the previous picture instead of swapping.
      if previewRevealStartedAt[id] == nil { previewRevealStartedAt[id] = now }
      // Always start the link: a window moved to another monitor mid-fade needs that monitor's link.
      startPreviewFadeAnimation(on: monitorID)
      panels[monitorID]?.view.updatePreview(picture, blurred: blurredPreviews[id]?.image, for: id,
        opacity: overviewPreviewOpacity(startedAt: previewRevealStartedAt[id], now: now,
          reduceMotion: reduceMotion))
    }
    showSharedDesktops(fadeDuration: reduceMotion ? 0 : overviewDesktopFadeDuration)
    deriveBlurs()
    if !removed.isEmpty { updatePanels(scheduleCaptures: false) }
  }

  private func showSharedDesktops(fadeDuration: TimeInterval) {
    guard !usesWorkspaceParking else { return }
    for (monitorID, panel) in panels {
      guard let displayID = CGDirectDisplayID(exactly: monitorID.rawValue),
        let background = WindowCaptureStore.shared.background(displayID),
        background !== shownDesktops[monitorID] else { continue }
      shownDesktops[monitorID] = background
      // The full-resolution wallpaper the ribbon uses; the layer scales it.
      panel.setDesktopImage(NSImage(cgImage: background, size: panel.window.frame.size),
        fadeDuration: panel.view.hasDesktopImage ? fadeDuration : 0)
    }
  }

  /// One small blurred copy per shown picture, visible cards first, off the main thread.
  private func deriveBlurs() {
    guard blurTask == nil else { return }
    blurTask = Task { @MainActor [weak self] in
      while let self, let (id, picture, image) = self.nextBlur() {
        let blurred = await Task.detached(priority: .userInitiated) {
          overviewBlurredPreview(image)
        }.value
        guard !Task.isCancelled else { break }
        self.blurredPreviews[id] = (ObjectIdentifier(picture.contents), blurred)
        if self.previews[id] == picture { self.updatePanels(scheduleCaptures: false) }
      }
      self?.blurTask = nil
    }
  }

  private func nextBlur() -> (WindowID, WindowPicture, CGImage)? {
    let pending = previews.filter { id, picture in
      picture.image != nil && blurredPreviews[id]?.source != ObjectIdentifier(picture.contents)
    }
    guard let (id, picture) = pending.first(where: { previewMonitorIDs[$0.key] != nil }) ?? pending.first,
      let image = picture.image else { return nil }
    return (id, picture, image)
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

  func releaseIdleOverviewResources() {
    guard !isOpen else { return }
    defer { presentationChanged() }
    // Expiry may beat a delayed closing-animation continuation. Hiding first
    // prevents cancellation from leaving an input-blocking panel on screen.
    for panel in panels.values { panel.hide() }
    snapshot = nil
    projections.removeAll()
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
    let rendersBefore = view?.renderCount ?? 0
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
    if (view?.renderCount ?? 0) > rendersBefore {
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
