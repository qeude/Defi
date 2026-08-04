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
  if windowBorderAlpha(of: style.activeColor) > 0 {
    active = tracked.first { $0.windowID == selectedWindowID }
  } else {
    active = nil
  }
  guard style.inactiveEnabled, windowBorderAlpha(of: style.inactiveColor) > 0 else {
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

func windowBorderAlpha(of color: UInt32) -> UInt8 {
  UInt8((color >> 24) & 0xff)
}

func borderOpacity(_ color: UInt32) -> Float {
  Float(windowBorderAlpha(of: color)) / 255
}
