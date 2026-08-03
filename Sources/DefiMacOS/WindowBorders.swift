import AppKit
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
        windowRadius: 9,
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
        windowRadius: 9,
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
          windowRadius: 9,
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
        windowRadius: 9,
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

  func skyLightCompanions() -> [WindowID: [SkyLightPositionCompanion]] {
    Dictionary(
      uniqueKeysWithValues: overlays.compactMap { windowID, overlay in
        let companions = overlay.skyLightCompanions
        return companions.isEmpty ? nil : (windowID, companions)
      }
    )
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
