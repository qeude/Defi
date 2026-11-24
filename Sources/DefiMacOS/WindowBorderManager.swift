import AppKit
import CoreFoundation
import Darwin
import DefiCore
import DefiModel
import DefiRuntime

@MainActor
final class WindowBorderManager {
  private let radiusProvider = WindowCornerRadiusProvider()
  private var overlays: [WindowID: BorderOverlay] = [:]
  /// Hidden overlays of untracked windows, kept for the next workspace: creating border
  /// panels mid-motion costs the overlay about half of its 120 Hz frames.
  private var spareOverlays: [BorderOverlay] = []
  private(set) var activeWindowID: WindowID?
  private var lastPlan: WindowBorderRenderPlan?
  private var lastDisplayedFrames: [WindowID: Rect] = [:]
  private var compositorCommitPending = false
  private(set) var isSuppressed = false
  /// Windows each display's ribbon overlay draws itself: their native borders hide
  /// without teardown.
  private var presentationHiddenByDisplay: [UInt32: Set<WindowID>] = [:]
  /// Windows a landed motion left out of view, with the frame they left: hidden until a
  /// plan drops them or places them elsewhere, such as on another display, since the plan
  /// of their old place arrives after the overlay lifts.
  private var departedFrames: [WindowID: Rect?] = [:]
  private var presentationHiddenWindowIDs: Set<WindowID> = []
  func setPresentationHidden(
    _ windowIDs: Set<WindowID>, for display: UInt32, departed: Set<WindowID> = [], landed: Set<WindowID> = []
  ) {
    presentationHiddenByDisplay[display] = windowIDs.isEmpty ? nil : windowIDs
    // A new motion draws these windows again, and a landing that leaves them on screen
    // shows them, such as one that arrived from another display's motion.
    for windowID in windowIDs.union(landed) { departedFrames.removeValue(forKey: windowID) }
    for windowID in departed {
      departedFrames.updateValue(lastPlan?.tracked.first { $0.windowID == windowID }?.frame, forKey: windowID)
    }
    updatePresentationHidden()
  }

  /// Windows on a display that shows a full-screen Space.
  func setFullscreenHidden(_ windowIDs: Set<WindowID>) {
    presentationHiddenByDisplay[fullscreenHiddenKey] = windowIDs.isEmpty ? nil : windowIDs
    updatePresentationHidden()
  }
  private let fullscreenHiddenKey = UInt32.max
  var fullscreenHiddenWindowIDs: Set<WindowID> { presentationHiddenByDisplay[fullscreenHiddenKey] ?? [] }

  private func updatePresentationHidden() {
    let hidden = presentationHiddenByDisplay.values.reduce(into: Set(departedFrames.keys)) { $0.formUnion($1) }
    guard hidden != presentationHiddenWindowIDs else { return }
    presentationHiddenWindowIDs = hidden
    for (windowID, overlay) in overlays { overlay.setPresentationHidden(hidden.contains(windowID)) }
    CATransaction.flush()
  }
  /// Corner radii last sent to the ribbon overlay, which draws the same rings.
  private var reportedRadii: [WindowID: Double] = [:]
  private var appliedPlans = 0
  private var skippedPlans = 0
  private var geometryUpdateCount = 0
  /// Moves border surfaces atomically; returns false to request the AppKit path.
  var surfaceMover: (([BorderSurfaceMove]) -> Bool)?
  /// WindowServer bounds of an edge surface; nil skips the stale-edge check.
  var surfaceBounds: ((UInt32) -> Rect?)?
  var trace: ((String) -> Void)?

  var performance: WindowBorderPerformance {
    let visible = overlays.values.lazy.filter(\.isVisible).count
    return WindowBorderPerformance(
      allocated: overlays.count + spareOverlays.count,
      visible: visible,
      dormant: overlays.count + spareOverlays.count - visible,
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

  var dimmedWindowIDs: Set<WindowID> {
    Set(overlays.compactMap { $0.value.isVisible && $0.value.dim > 0 ? $0.key : nil })
  }

  /// Windows whose dim may be elevated: every shown overlay while the dim is on.
  var dimCandidateWindowIDs: Set<WindowID> {
    guard (lastPlan?.style.inactiveDim ?? 0) > 0 else { return [] }
    return liveGeometryWindowIDs
  }

  func setDimElevations(_ elevated: Set<WindowID>) {
    for (windowID, overlay) in overlays { overlay.setDimElevated(elevated.contains(windowID)) }
  }

  var hasElevatedDim: Bool { overlays.values.contains { $0.dimElevation == true } }

  func lowerDims(overlapping frame: Rect, movedWindowID: WindowID) {
    for (windowID, overlay) in overlays where windowID != movedWindowID {
      overlay.lowerDim(ifOverlapping: frame)
    }
  }

  var liveGeometryWindowIDs: Set<WindowID> {
    Set(
      overlays.compactMap { windowID, overlay in
        overlay.isVisible ? windowID : nil
      })
  }

  var transparentSurfaceWindowIDs: Set<CGWindowID> {
    (overlays.values + spareOverlays).reduce(into: Set<CGWindowID>()) {
      $0.formUnion($1.windowIDs)
    }
  }

  var ownedSurfaceWindowID: WindowID? {
    for overlay in overlays.values {
      if let windowID = overlay.ownedSurfaceWindowID {
        return windowID
      }
    }
    return nil
  }

  func showsActiveRing(for windowID: WindowID) -> Bool {
    // Suppressed borders never come back on their own: nothing to wait for.
    guard !isSuppressed else { return true }
    guard activeWindowID == windowID, let overlay = overlays[windowID] else { return false }
    return !overlay.isPresentationHidden && overlay.isVisible && overlay.opacity > 0
  }

  /// Whether the focused window's ring and the dims of `windowIDs` are on screen.
  func showsNativeBorders(ring windowID: WindowID?, dimming windowIDs: Set<WindowID>) -> Bool {
    guard !isSuppressed else { return true }
    if let windowID, !showsActiveRing(for: windowID) { return false }
    return windowIDs.allSatisfy { overlays[$0]?.showsDim == true }
  }

  private var pendingPulse: (windowID: WindowID, requestedAt: CFTimeInterval)?

  func pulseActiveRing(for windowID: WindowID, requestedAt: CFTimeInterval = CACurrentMediaTime()) {
    pendingPulse = nil
    // A pulse still waiting for its ring after the flash would have ended is dropped.
    guard !isSuppressed, CACurrentMediaTime() - requestedAt < 0.5, activeWindowID == windowID,
      let overlay = overlays[windowID], !overlay.isPresentationHidden
    else { return }
    if overlay.revealIsPending { return pendingPulse = (windowID, requestedAt) }
    overlay.pulseSideEdges()
  }

  func revealPendingBorders() {
    guard !isSuppressed else { return }
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
    displayedFrame: Rect?
  ) {
    guard !isSuppressed, activeWindowID != windowID else { return }
    let previousActiveWindowID = activeWindowID
    activeWindowID = windowID
    guard let style = lastPlan?.style else {
      return
    }
    if let previousActiveWindowID,
      let overlay = overlays[previousActiveWindowID],
      overlay.isVisible
    {
      if !style.inactiveEnabled, style.inactiveDim == 0, style.enabled, style.width > 0,
        windowBorderAlpha(of: style.activeColor) > 0,
        let windowID, displayedFrame != nil, overlays[windowID] == nil
      {
        overlay.retarget(to: windowID, preservingBacking: true)
        overlay.setPresentationHidden(presentationHiddenWindowIDs.contains(windowID))
        overlays[previousActiveWindowID] = nil
        overlays[windowID] = overlay
      } else {
        overlay.setStacking(.inactive(for: previousActiveWindowID))
        if style.inactiveEnabled {
          overlay.updateAppearance(to: style.inactiveColor)
        } else if style.inactiveDim > 0 {
          overlay.removeRing()
        } else {
          overlay.hide()
        }
        overlay.setDim(style.inactiveDim, animated: true)
      }
    }
    if let windowID { overlays[windowID]?.setDim(0, animated: false) }
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
      overlay.setStacking(.inactive(for: windowID))
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
    guard !isSuppressed else { return false }
    var geometryChanged = false
    let moveBatch = surfaceMover.map { _ in BorderSurfaceMoveBatch() }
    for (windowID, frame) in frames {
      guard let overlay = overlays[windowID], overlay.isVisible else { continue }
      let changed = overlay.syncGeometry(
        frame: frame,
        width: style.width,
        windowRadius: radius(for: windowID),
        captureEnabled: style.captureEnabled,
        placement: style.placement,
        moveBatch: moveBatch
      )
      if changed {
        geometryChanged = true
        geometryUpdateCount += 1
      }
    }
    if let moveBatch, let surfaceMover {
      if !moveBatch.moves.isEmpty { moveBatch.complete(moved: surfaceMover(moveBatch.moves)) }
      traceStaleEdges(moveBatch.commits)
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
    guard !isSuppressed else { return }
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
      commitVisibleOverlays()
      return
    }
    lastPlan = plan
    lastDisplayedFrames = displayedFrames
    appliedPlans += 1
    if !departedFrames.isEmpty {
      departedFrames = remainingBorderDepartures(departedFrames, tracked: plan.tracked)
      updatePresentationHidden()
    }
    let now = CACurrentMediaTime()
    closingUntil = closingUntil.filter { $0.value > now && trackedWindowIDs.contains($0.key) }
    radiusProvider.retain(
      windowIDs: trackedWindowIDs.union(overlays.keys)
    )
    let radii = Dictionary(uniqueKeysWithValues: trackedWindowIDs.map { ($0, radius(for: $0)) })
    if radii != reportedRadii {
      reportedRadii = radii
      NavigationActor.enqueue { RibbonProxyPresenter.cornerRadii.merge(radii) { $1 } }
    }
    // With a dim, the focused window keeps its overlay too: refocusing only changes opacities.
    let desiredAssignments = (plan.style.inactiveDim > 0 ? plan.tracked : plan.inactive + [plan.active].compactMap { $0 })
      .filter { closingUntil[$0.windowID] == nil }
    let desiredWindowIDs = Set(desiredAssignments.map(\.windowID))
    for assignment in desiredAssignments where overlays[assignment.windowID] == nil {
      _ = reusableOrNewOverlay(
        for: assignment.windowID,
        excluding: desiredWindowIDs
      )
    }

    if plan.style.inactiveDim == 0 {
      for overlay in overlays.values + spareOverlays { overlay.releaseDim() }
    }
    let inactiveWindowIDs = Set(plan.inactive.map(\.windowID))
    let dimmedWindowIDs = Set(plan.dimmed.map(\.windowID))
    for assignment in desiredAssignments {
      guard let overlay = overlays[assignment.windowID] else { continue }
      let windowID = assignment.windowID
      let isActive = windowID == plan.active?.windowID
      overlay.setStacking(isActive && stacking.targetWindowID == windowID ? stacking : .inactive(for: windowID))
      let wasShown = overlay.isVisible
      var ringColor: UInt32?
      if isActive {
        ringColor = plan.style.activeColor
      } else if inactiveWindowIDs.contains(windowID) {
        ringColor = plan.style.inactiveColor
      }
      let frame = displayedFrames[windowID] ?? assignment.frame
      overlay.sync(
        frame: frame,
        width: plan.style.width,
        color: ringColor,
        windowRadius: radius(for: windowID),
        captureEnabled: plan.style.captureEnabled,
        placement: plan.style.placement
      )
      // Until the next stacking read, Defi's own windows decide: an arriving window's app
      // brought forward must not lift the window over a dim just above it.
      if overlay.dimElevation == nil {
        overlay.setDimElevated(!plan.tracked.contains {
          $0.windowID != windowID && targetIntersects($0.frame, monitor: frame)
        })
      }
      overlay.setDim(dimmedWindowIDs.contains(windowID) ? plan.style.inactiveDim : 0, animated: wasShown)
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
      // A workspace shows a handful of borders; spares beyond that are released.
      guard let overlay = overlays.removeValue(forKey: windowID) else { continue }
      if spareOverlays.count < 4 { spareOverlays.append(overlay) } else { overlay.close() }
    }
    compositorCommitPending = true
  }

  /// Windows closing: plans keep them until the next snapshot drops them.
  private var closingUntil: [WindowID: CFTimeInterval] = [:]
  func isClosing(_ windowID: WindowID) -> Bool { closingUntil[windowID].map { $0 > CACurrentMediaTime() } ?? false }
  /// A closing window's ring goes at once: macOS shrinks the window for ~180 ms first,
  /// which the ring would outline.
  func hideClosing(_ windowID: WindowID) {
    // shortcut: a window wrongly reported closed gets its ring back only with the next
    // plan change after 1 s; track destroyed elements if one ever stays.
    closingUntil[windowID] = CACurrentMediaTime() + 1
    guard let overlay = overlays[windowID], overlay.isVisible else { return }
    overlay.hide()
    CATransaction.flush()
  }

  func hide() {
    for overlay in overlays.values {
      overlay.hide()
    }
    // Hidden overlays stay as a dormant pool: creating border panels again on the next
    // reveal costs WindowServer round trips that stalled the overview and workspace motion.
    activeWindowID = nil
    lastPlan = nil
    lastDisplayedFrames.removeAll(keepingCapacity: true)
    compositorCommitPending = false
  }

  func setSuppressed(_ suppressed: Bool) {
    guard isSuppressed != suppressed else { return }
    isSuppressed = suppressed
    if suppressed {
      hide()
    }
  }

  func expectedEdgeFrames(
    windowFrame: (WindowID) -> Rect?
  ) -> [WindowID: [UInt32: Rect]] {
    overlays.reduce(into: [:]) { result, entry in
      guard entry.value.isVisible, let frame = windowFrame(entry.key) else { return }
      result[entry.key] = entry.value.expectedEdgeFrames(for: frame)
    }
  }

  private func traceStaleEdges(_ commits: [BorderSurfaceMoveBatch.Commit]) {
    guard let surfaceBounds, let trace else { return }
    for commit in commits {
      guard let actual = surfaceBounds(commit.windowNumber) else { continue }
      let error = windowBorderFrameError(commit.frame, actual)
      guard error > windowBorderAuditTolerance else { continue }
      trace(
        "border-stale wid=\(commit.targetWindowNumber) edge=\(commit.windowNumber)"
          + " err=\(String(format: "%.1f", error))")
    }
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
    if let pendingPulse { pulseActiveRing(for: pendingPulse.windowID, requestedAt: pendingPulse.requestedAt) }
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
      overlay.setPresentationHidden(presentationHiddenWindowIDs.contains(windowID))
      overlays[windowID] = overlay
      return overlay
    }
    if let overlay = spareOverlays.popLast() {
      overlay.retarget(to: windowID)
      overlay.setPresentationHidden(presentationHiddenWindowIDs.contains(windowID))
      overlays[windowID] = overlay
      return overlay
    }
    let overlay = BorderOverlay(windowID: windowID)
    overlay.setPresentationHidden(presentationHiddenWindowIDs.contains(windowID))
    overlays[windowID] = overlay
    return overlay
  }
}

/// Departed windows stay hidden while a plan still tracks them where they left; one the
/// plan drops or places elsewhere, such as on another display, shows again.
func remainingBorderDepartures(_ departed: [WindowID: Rect?], tracked: [FrameAssignment]) -> [WindowID: Rect?] {
  let frames = Dictionary(tracked.map { ($0.windowID, $0.frame) }, uniquingKeysWith: { first, _ in first })
  return departed.filter { windowID, left in frames[windowID].map { left == nil || $0 == left } ?? false }
}
