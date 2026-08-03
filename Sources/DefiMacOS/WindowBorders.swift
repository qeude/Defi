import AppKit
import CoreFoundation
import Darwin
import DefiCore
import DefiModel

struct WindowBorderAssignment: Equatable, Sendable {
  let windowID: WindowID
  let frame: Rect
}

struct WindowBorderStyle: Equatable, Sendable {
  let enabled: Bool
  let width: Double
  let activeColor: UInt32
  let inactiveEnabled: Bool
  let inactiveColor: UInt32
  let captureEnabled: Bool
}

struct WindowBorderRenderPlan: Equatable, Sendable {
  let active: WindowBorderAssignment?
  let inactive: [WindowBorderAssignment]
  let tracked: [WindowBorderAssignment]
  let style: WindowBorderStyle
}

public struct WindowBorderPerformance: Equatable, Sendable {
  public let allocated: Int
  public let visible: Int
  public let dormant: Int
  public let activeOpacity: Double
  public let estimatedSurfacePixels: Int
  public let appliedPlans: Int
  public let skippedPlans: Int
  public let geometryUpdates: Int
  public let captureEnabled: Bool

  public init(
    allocated: Int,
    visible: Int,
    dormant: Int,
    activeOpacity: Double,
    estimatedSurfacePixels: Int,
    appliedPlans: Int,
    skippedPlans: Int,
    geometryUpdates: Int,
    captureEnabled: Bool
  ) {
    self.allocated = allocated
    self.visible = visible
    self.dormant = dormant
    self.activeOpacity = activeOpacity
    self.estimatedSurfacePixels = estimatedSurfacePixels
    self.appliedPlans = appliedPlans
    self.skippedPlans = skippedPlans
    self.geometryUpdates = geometryUpdates
    self.captureEnabled = captureEnabled
  }
}

func planWindowBorders(
  frames: [FrameAssignment],
  selectedWindowID: WindowID?,
  hiddenWindowIDs: Set<WindowID>,
  monitorFrames: [Rect],
  style: WindowBorderStyle
) -> WindowBorderRenderPlan {
  guard style.enabled, style.width > 0 else {
    return WindowBorderRenderPlan(
      active: nil,
      inactive: [],
      tracked: [],
      style: style
    )
  }
  let isVisible: (FrameAssignment) -> Bool = {
    (!hiddenWindowIDs.contains($0.windowID)
      || $0.windowID == selectedWindowID)
      && frameIntersectsAnyMonitor($0.frame, monitorFrames: monitorFrames)
  }
  let tracked = frames.compactMap { assignment -> WindowBorderAssignment? in
    guard isVisible(assignment) else { return nil }
    return WindowBorderAssignment(
      windowID: assignment.windowID,
      frame: assignment.frame
    )
  }.sorted { $0.windowID.rawValue < $1.windowID.rawValue }
  let active: WindowBorderAssignment?
  if alpha(of: style.activeColor) > 0 {
    active = tracked.first { $0.windowID == selectedWindowID }
  } else {
    active = nil
  }
  guard style.inactiveEnabled, alpha(of: style.inactiveColor) > 0 else {
    return WindowBorderRenderPlan(
      active: active,
      inactive: [],
      tracked: tracked,
      style: style
    )
  }
  let inactive = tracked.filter { $0.windowID != active?.windowID }
  return WindowBorderRenderPlan(
    active: active,
    inactive: inactive,
    tracked: tracked,
    style: style
  )
}

func borderCornerRadius(windowRadius: Double) -> Double {
  max(windowRadius, 0)
}

func resolvedWindowBorderRadius(nativeRadius: Double?) -> Double {
  guard let nativeRadius, nativeRadius.isFinite, nativeRadius > 0 else {
    return 9
  }
  return nativeRadius
}

func resolvedWindowBorderFrame(
  nativeFrame: Rect?,
  observedFrame: Rect?,
  plannedFrame: Rect?
) -> Rect? {
  nativeFrame ?? observedFrame ?? plannedFrame
}

private func frameIntersectsAnyMonitor(
  _ frame: Rect,
  monitorFrames: [Rect]
) -> Bool {
  monitorFrames.contains {
    frame.x + frame.width > $0.x
      && frame.x < $0.x + $0.width
      && frame.y + frame.height > $0.y
      && frame.y < $0.y + $0.height
  }
}

private func alpha(of color: UInt32) -> UInt8 {
  UInt8((color >> 24) & 0xff)
}

func borderOpacity(_ color: UInt32) -> Float {
  Float(alpha(of: color)) / 255
}

@MainActor
final class WindowBorderManager {
  private let radiusProvider = WindowCornerRadiusProvider()
  private var overlays: [WindowID: BorderOverlay] = [:]
  private(set) var activeWindowID: WindowID?
  private var lastPlan: WindowBorderRenderPlan?
  private var lastDisplayedFrames: [WindowID: Rect] = [:]
  private var compositorCommitPending = false
  private var appliedPlans = 0
  private var skippedPlans = 0
  private var geometryUpdateCount = 0

  var performance: WindowBorderPerformance {
    let visible = overlays.values.lazy.filter(\.isVisible).count
    return WindowBorderPerformance(
      allocated: overlays.count,
      visible: visible,
      dormant: overlays.count - visible,
      activeOpacity: activeWindowID.flatMap { overlays[$0]?.opacity } ?? 0,
      estimatedSurfacePixels: overlays.values.reduce(0) {
        $0 + $1.estimatedSurfacePixels
      },
      appliedPlans: appliedPlans,
      skippedPlans: skippedPlans,
      geometryUpdates: geometryUpdateCount,
      captureEnabled: lastPlan?.style.captureEnabled ?? false
    )
  }

  var liveGeometryWindowIDs: Set<WindowID> {
    Set(
      overlays.compactMap { windowID, overlay in
        overlay.isVisible ? windowID : nil
      })
  }

  func revealPendingBorders() {
    compositorCommitPending = true
    commitVisibleOverlays()
    revealPendingOpacities(in: overlays.values.filter(\.isVisible))
  }

  func prepareForSelection(
    _ windowID: WindowID?,
    displayedFrame: Rect?
  ) {
    guard activeWindowID != windowID else { return }
    let previousActiveWindowID = activeWindowID
    activeWindowID = windowID
    guard let style = lastPlan?.style else {
      return
    }
    if let previousActiveWindowID,
      let overlay = overlays[previousActiveWindowID],
      overlay.isVisible
    {
      if style.inactiveEnabled {
        overlay.updateAppearance(to: style.inactiveColor)
      } else {
        overlay.hide()
      }
    }
    if style.enabled,
      style.width > 0,
      alpha(of: style.activeColor) > 0,
      let windowID,
      let displayedFrame
    {
      let overlay: BorderOverlay
      if let existing = overlays[windowID] {
        overlay = existing
      } else {
        let created = BorderOverlay(
          windowID: windowID
        )
        overlays[windowID] = created
        overlay = created
      }
      _ = overlay.syncGeometry(
        frame: displayedFrame,
        width: style.width,
        windowRadius: radius(for: windowID),
        captureEnabled: style.captureEnabled
      )
      overlay.prepareReveal(to: style.activeColor)
    }
    compositorCommitPending = true
  }

  @discardableResult
  func updateGeometry(
    frames: [WindowID: Rect],
    style: WindowBorderStyle
  ) -> Bool {
    var geometryChanged = false
    for (windowID, frame) in frames {
      guard let overlay = overlays[windowID], overlay.isVisible else { continue }
      let changed = overlay.syncGeometry(
        frame: frame,
        width: style.width,
        windowRadius: radius(for: windowID),
        captureEnabled: style.captureEnabled
      )
      if changed {
        geometryChanged = true
        geometryUpdateCount += 1
      }
    }
    if compositorCommitPending || geometryChanged {
      commitVisibleOverlays()
    }
    return geometryChanged
  }

  func sync(
    _ plan: WindowBorderRenderPlan,
    displayedFrames: [WindowID: Rect]
  ) {
    let trackedWindowIDs = Set(plan.tracked.map(\.windowID))
    guard plan != lastPlan || displayedFrames != lastDisplayedFrames else {
      skippedPlans += 1
      return
    }
    lastPlan = plan
    lastDisplayedFrames = displayedFrames
    appliedPlans += 1
    radiusProvider.retain(
      windowIDs: trackedWindowIDs.union(overlays.keys)
    )
    let desiredAssignments = plan.inactive + [plan.active].compactMap { $0 }
    for assignment in desiredAssignments where overlays[assignment.windowID] == nil {
      overlays[assignment.windowID] = BorderOverlay(
        windowID: assignment.windowID
      )
    }

    if let assignment = plan.active {
      if let overlay = overlays[assignment.windowID] {
        overlay.sync(
          frame: displayedFrames[assignment.windowID] ?? assignment.frame,
          width: plan.style.width,
          color: plan.style.activeColor,
          windowRadius: radius(for: assignment.windowID),
          captureEnabled: plan.style.captureEnabled
        )
      }
    }

    for assignment in plan.inactive {
      guard let overlay = overlays[assignment.windowID] else { continue }
      overlay.sync(
        frame: displayedFrames[assignment.windowID] ?? assignment.frame,
        width: plan.style.width,
        color: plan.style.inactiveColor,
        windowRadius: radius(for: assignment.windowID),
        captureEnabled: plan.style.captureEnabled
      )
    }

    let desiredWindowIDs = Set(desiredAssignments.map(\.windowID))
    var removedWindowIDs: [WindowID] = []
    for (windowID, overlay) in overlays
    where !desiredWindowIDs.contains(windowID) {
      if overlay.isVisible {
        overlay.hide()
      }
      if !trackedWindowIDs.contains(windowID) {
        removedWindowIDs.append(windowID)
      }
    }
    for windowID in removedWindowIDs {
      overlays[windowID] = nil
    }
    compositorCommitPending = true
  }

  func hide() {
    for overlay in overlays.values {
      overlay.hide()
    }
    overlays.removeAll(keepingCapacity: true)
    activeWindowID = nil
    lastPlan = nil
    lastDisplayedFrames.removeAll(keepingCapacity: true)
    compositorCommitPending = false
  }

  private func commitVisibleOverlays() {
    let visibleOverlays = overlays.values.filter(\.isVisible)
    guard !visibleOverlays.isEmpty else {
      compositorCommitPending = false
      return
    }
    for overlay in visibleOverlays {
      overlay.applyCompositorFallback()
    }
    compositorCommitPending = false
  }

  private func revealPendingOpacities(
    in overlays: [BorderOverlay]
  ) {
    for overlay in overlays {
      overlay.revealPendingOpacity()
    }
  }

  private func radius(for windowID: WindowID) -> Double {
    radiusProvider.radius(for: windowID)
  }
}

func normalizedWindowBorderFrame(_ bounds: CGRect) -> Rect? {
  guard bounds.origin.x.isFinite,
    bounds.origin.y.isFinite,
    bounds.size.width.isFinite,
    bounds.size.height.isFinite,
    bounds.size.width > 0,
    bounds.size.height > 0
  else {
    return nil
  }
  return Rect(
    x: Double(bounds.origin.x),
    y: Double(bounds.origin.y),
    width: Double(bounds.size.width),
    height: Double(bounds.size.height)
  )
}

func windowBorderFrameSnapshot(
  windowIDs: Set<WindowID>,
  frameProvider: (WindowID) -> Rect?
) -> [WindowID: Rect] {
  Dictionary(
    uniqueKeysWithValues: windowIDs.compactMap { windowID in
      frameProvider(windowID).map { (windowID, $0) }
    }
  )
}

final class WindowServerBoundsProvider {
  private typealias MainConnectionIDFunc = @convention(c) () -> Int32
  private typealias GetWindowBoundsFunc =
    @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32

  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let getWindowBounds: GetWindowBoundsFunc?

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle

    func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
      guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }

    mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
    getWindowBounds = resolve("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  func frame(for windowID: WindowID) -> Rect? {
    guard let rawWindowID = UInt32(exactly: windowID.rawValue),
      let mainConnectionID,
      let getWindowBounds
    else {
      return nil
    }
    var bounds = CGRect.zero
    guard getWindowBounds(mainConnectionID(), rawWindowID, &bounds) == 0 else {
      return nil
    }
    return normalizedWindowBorderFrame(bounds)
  }
}

private final class WindowCornerRadiusProvider {
  private typealias MainConnectionIDFunc = @convention(c) () -> Int32
  private typealias WindowQueryFunc =
    @convention(c) (Int32, UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
  private typealias QueryCopyWindowsFunc =
    @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
  private typealias IteratorCountFunc = @convention(c) (UnsafeRawPointer?) -> Int32
  private typealias IteratorAdvanceFunc = @convention(c) (UnsafeRawPointer?) -> Bool
  private typealias IteratorCornerRadiiFunc =
    @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?

  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let windowQuery: WindowQueryFunc?
  private let queryCopyWindows: QueryCopyWindowsFunc?
  private let iteratorCount: IteratorCountFunc?
  private let iteratorAdvance: IteratorAdvanceFunc?
  private let iteratorCornerRadii: IteratorCornerRadiiFunc?
  private var cache: [WindowID: Double] = [:]

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle

    func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
      guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }

    mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
    windowQuery = resolve("SLSWindowQueryWindows", as: WindowQueryFunc.self)
    queryCopyWindows = resolve(
      "SLSWindowQueryResultCopyWindows",
      as: QueryCopyWindowsFunc.self
    )
    iteratorCount = resolve("SLSWindowIteratorGetCount", as: IteratorCountFunc.self)
    iteratorAdvance = resolve(
      "SLSWindowIteratorAdvance",
      as: IteratorAdvanceFunc.self
    )
    iteratorCornerRadii = resolve(
      "SLSWindowIteratorGetCornerRadii",
      as: IteratorCornerRadiiFunc.self
    )
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  func retain(windowIDs: Set<WindowID>) {
    cache = cache.filter { windowIDs.contains($0.key) }
  }

  func radius(for windowID: WindowID) -> Double {
    if let cached = cache[windowID] { return cached }
    let radius = resolvedWindowBorderRadius(
      nativeRadius: readRadius(for: windowID)
    )
    cache[windowID] = radius
    return radius
  }

  private func readRadius(for windowID: WindowID) -> Double? {
    guard let rawWindowID = UInt32(exactly: windowID.rawValue),
      let mainConnectionID,
      let windowQuery,
      let queryCopyWindows,
      let iteratorCount,
      let iteratorAdvance,
      let iteratorCornerRadii
    else {
      return nil
    }
    let windowIDs = NSArray(object: NSNumber(value: rawWindowID))
    let windowIDsPointer = Unmanaged.passUnretained(windowIDs).toOpaque()
    guard let query = windowQuery(mainConnectionID(), windowIDsPointer, 0) else {
      return nil
    }
    defer { Unmanaged<AnyObject>.fromOpaque(query).release() }
    guard let iterator = queryCopyWindows(query) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(iterator).release() }
    guard iteratorCount(iterator) > 0, iteratorAdvance(iterator) else { return nil }
    guard let radii = iteratorCornerRadii(iterator) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(radii).release() }
    let values = Unmanaged<CFArray>.fromOpaque(radii).takeUnretainedValue()
    guard CFArrayGetCount(values) > 0,
      let rawValue = CFArrayGetValueAtIndex(values, 0)
    else {
      return nil
    }
    let value = Unmanaged<NSNumber>.fromOpaque(
      UnsafeMutableRawPointer(mutating: rawValue)
    ).takeUnretainedValue().doubleValue
    return value > 0 && value.isFinite ? value : nil
  }
}
