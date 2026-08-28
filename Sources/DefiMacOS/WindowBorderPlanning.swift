import AppKit
import CoreFoundation
import Darwin
import DefiConfig
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
  let placement: WindowBorderPlacement

  init(
    enabled: Bool,
    width: Double,
    activeColor: UInt32,
    inactiveEnabled: Bool,
    inactiveColor: UInt32,
    captureEnabled: Bool,
    placement: WindowBorderPlacement = .inside
  ) {
    self.enabled = enabled
    self.width = width
    self.activeColor = activeColor
    self.inactiveEnabled = inactiveEnabled
    self.inactiveColor = inactiveColor
    self.captureEnabled = captureEnabled
    self.placement = placement
  }

  init(config: BordersConfig) {
    self.init(
      enabled: config.enabled,
      width: config.width,
      activeColor: parseBorderColor(config.color) ?? 0xffc0_99ff,
      inactiveEnabled: config.inactiveEnabled,
      inactiveColor: parseBorderColor(config.inactiveColor) ?? 0x66c0_99ff,
      captureEnabled: config.captureEnabled,
      placement: WindowBorderPlacement(configValue: config.placement)
    )
  }
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

func overviewWindowBorderAppearance(
  isSelected: Bool,
  style: WindowBorderStyle,
  scale: Double
) -> (color: UInt32, width: Double)? {
  let width = style.width * scale
  guard style.enabled, width > 0 else { return nil }
  if isSelected, windowBorderAlpha(of: style.activeColor) > 0 {
    return (style.activeColor, width)
  }
  guard style.inactiveEnabled, windowBorderAlpha(of: style.inactiveColor) > 0 else {
    return nil
  }
  return (style.inactiveColor, width)
}

func overviewWindowBorderGeometry(
  cardFrame: Rect,
  cardRadius: Double,
  width: Double,
  placement: WindowBorderPlacement
) -> (frame: Rect, radius: Double) {
  let inset = placement == .inside ? width / 2 : -width / 2
  return (
    Rect(
      x: cardFrame.x + inset,
      y: cardFrame.y + inset,
      width: cardFrame.width - inset * 2,
      height: cardFrame.height - inset * 2
    ),
    max(cardRadius - inset, 0)
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
