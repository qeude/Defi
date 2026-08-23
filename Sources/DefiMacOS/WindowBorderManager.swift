import AppKit
import CoreFoundation
import Darwin
import DefiCore
import DefiModel

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

  var transparentSurfaceWindowIDs: Set<CGWindowID> {
    overlays.values.reduce(into: Set<CGWindowID>()) {
      $0.formUnion($1.windowIDs)
    }
  }

  var ownedSurfaceWindowID: WindowID? {
    for overlay in overlays.values {
      if let windowID = overlay.windowIDs.first {
        return WindowID(rawValue: UInt64(windowID))
      }
    }
    return nil
  }

  func revealPendingBorders() {
    compositorCommitPending = true
    commitVisibleOverlays()
    revealPendingOpacities(in: overlays.values.filter(\.isVisible))
  }

  func updateActiveStacking(
    for expectedActiveWindowID: WindowID,
    stacking: WindowBorderStacking
  ) {
    guard activeWindowID == expectedActiveWindowID,
      stacking.targetWindowID == expectedActiveWindowID,
      let overlay = overlays[expectedActiveWindowID]
    else {
      return
    }
    overlay.setStacking(stacking)
  }

  func prepareForSelection(
    _ windowID: WindowID?,
    displayedFrame: Rect?,
    stacking: WindowBorderStacking? = nil
  ) {
    let activeStacking = stacking ?? .inactive(for: windowID)
    if activeWindowID == windowID {
      if let windowID {
        updateActiveStacking(
          for: windowID,
          stacking: activeStacking
        )
      }
      return
    }
    let previousActiveWindowID = activeWindowID
    activeWindowID = windowID
    guard let style = lastPlan?.style else {
      return
    }
    if let previousActiveWindowID,
      let overlay = overlays[previousActiveWindowID],
      overlay.isVisible
    {
      overlay.setStacking(.inactive(for: previousActiveWindowID))
      if style.inactiveEnabled {
        overlay.updateAppearance(to: style.inactiveColor)
      } else {
        overlay.hide()
      }
    }
    if style.enabled,
      style.width > 0,
      windowBorderAlpha(of: style.activeColor) > 0,
      let windowID,
      let displayedFrame
    {
      let overlay: BorderOverlay
      if let existing = overlays[windowID] {
        overlay = existing
      } else {
        overlay = reusableOrNewOverlay(for: windowID)
      }
      overlay.setStacking(activeStacking)
      _ = overlay.syncGeometry(
        frame: displayedFrame,
        width: style.width,
        windowRadius: radius(for: windowID),
        captureEnabled: style.captureEnabled,
        placement: style.placement
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
        captureEnabled: style.captureEnabled,
        placement: style.placement
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
    displayedFrames: [WindowID: Rect],
    stacking: WindowBorderStacking
  ) {
    let trackedWindowIDs = Set(plan.tracked.map(\.windowID))
    if let activeWindowID = plan.active?.windowID {
      overlays[activeWindowID]?.setStacking(
        stacking.targetWindowID == activeWindowID
          ? stacking
          : .inactive(for: activeWindowID)
      )
    }
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
    let desiredWindowIDs = Set(desiredAssignments.map(\.windowID))
    for assignment in desiredAssignments where overlays[assignment.windowID] == nil {
      _ = reusableOrNewOverlay(
        for: assignment.windowID,
        excluding: desiredWindowIDs
      )
    }

    if let assignment = plan.active {
      if let overlay = overlays[assignment.windowID] {
        overlay.setStacking(
          stacking.targetWindowID == assignment.windowID
            ? stacking
            : .inactive(for: assignment.windowID)
        )
        overlay.sync(
          frame: displayedFrames[assignment.windowID] ?? assignment.frame,
          width: plan.style.width,
          color: plan.style.activeColor,
          windowRadius: radius(for: assignment.windowID),
          captureEnabled: plan.style.captureEnabled,
          placement: plan.style.placement
        )
      }
    }

    for assignment in plan.inactive {
      guard let overlay = overlays[assignment.windowID] else { continue }
      overlay.setStacking(.inactive(for: assignment.windowID))
      overlay.sync(
        frame: displayedFrames[assignment.windowID] ?? assignment.frame,
        width: plan.style.width,
        color: plan.style.inactiveColor,
        windowRadius: radius(for: assignment.windowID),
        captureEnabled: plan.style.captureEnabled,
        placement: plan.style.placement
      )
    }

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

  private func reusableOrNewOverlay(
    for windowID: WindowID,
    excluding reservedWindowIDs: Set<WindowID> = []
  ) -> BorderOverlay {
    if let (previousWindowID, overlay) = overlays.first(where: {
      !$0.value.isVisible && !reservedWindowIDs.contains($0.key)
    }) {
      overlays[previousWindowID] = nil
      overlay.retarget(to: windowID)
      overlays[windowID] = overlay
      return overlay
    }
    let overlay = BorderOverlay(windowID: windowID)
    overlays[windowID] = overlay
    return overlay
  }
}
