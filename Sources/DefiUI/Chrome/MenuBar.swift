import ApplicationServices
import Observation
import DefiConfig
import AppKit
import DefiMacOS

public struct MenuWorkspace: Equatable, Sendable {
  public let id: String
  public let label: String
  public let icon: String?
  public let position: Int
  public let isEmpty: Bool

  public init(id: String, label: String, icon: String? = nil, position: Int = 1, isEmpty: Bool = false) {
    self.id = id
    self.label = label
    self.icon = icon
    self.position = position
    self.isEmpty = isEmpty
  }
}

public struct MenuMonitor: Equatable, Sendable {
  public let id: UInt64
  public let isFocused: Bool
  public let activeWorkspace: String
  public let workspaces: [MenuWorkspace]
  /// Columns of the active workspace at their target scroll, in points from the strip's left edge.
  public let columns: [MenuColumn]
  public let focusedColumn: Int?
  public let stripWidth: Double

  public init(
    id: UInt64, isFocused: Bool, activeWorkspace: String, workspaces: [MenuWorkspace],
    columns: [MenuColumn] = [], focusedColumn: Int? = nil, stripWidth: Double = 0
  ) {
    self.id = id
    self.isFocused = isFocused
    self.activeWorkspace = activeWorkspace
    self.workspaces = workspaces
    self.columns = columns
    self.focusedColumn = focusedColumn
    self.stripWidth = stripWidth
  }
}

public struct MenuColumn: Equatable, Sendable {
  public let x: Double
  public let width: Double
  public let windows: Int
  /// The window a click on this column focuses.
  public let windowID: UInt64

  public init(x: Double, width: Double, windows: Int, windowID: UInt64) {
    self.x = x
    self.width = width
    self.windows = windows
    self.windowID = windowID
  }
}

@MainActor
@Observable
public final class MenuBarState {
  public var isInserted = true { didSet { onChange?() } }
  public private(set) var config = MenuBarConfig()
  /// Monitors in desk order, left to right.
  public private(set) var monitors: [MenuMonitor] = []
  public private(set) var needsAccessibilityPermission: Bool
  @ObservationIgnored var onChange: (() -> Void)?
  private let accessibilityTrusted: () -> Bool

  public init(accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
    self.accessibilityTrusted = accessibilityTrusted
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  public func refreshAccessibilityPermission() {
    needsAccessibilityPermission = !accessibilityTrusted()
  }

  var focusedMonitor: MenuMonitor? { monitors.first(where: \.isFocused) ?? monitors.first }
  public var workspaces: [MenuWorkspace] { focusedMonitor?.workspaces ?? [] }
  public var activeWorkspace: String { focusedMonitor?.activeWorkspace ?? "" }
  public var activeLabel: String {
    workspaces.first { $0.id == activeWorkspace }?.label ?? "–"
  }

  var displayedMonitors: [MenuMonitor] {
    switch config.show {
    // A display with nothing on it would add a lone mark that reads like a display number.
    case .all: monitors.filter { $0.isFocused || $0.workspaces.contains { !$0.isEmpty } }
    case .current: focusedMonitor.map { [$0] } ?? []
    case .active: focusedMonitor.map { monitor in
      [MenuMonitor(id: monitor.id, isFocused: true, activeWorkspace: monitor.activeWorkspace,
        workspaces: monitor.workspaces.filter { $0.id == monitor.activeWorkspace })]
    } ?? []
    }
  }

  public func update(monitors: [MenuMonitor], config: MenuBarConfig = MenuBarConfig()) {
    guard monitors != self.monitors || config != self.config else { return }
    self.monitors = monitors
    self.config = config
    onChange?()
  }
}

/// One workspace mark in the menu bar strip, in image points. Animations interpolate between two marks.
struct MenuBarMark: Equatable {
  var workspaceID: String
  var rect: CGRect
  var radius: CGFloat
  var fill: CGFloat
  var stroke: CGFloat
  var label: String?
  var icon: String?
  var contentAlpha: CGFloat
  /// The active workspace cuts its label out of the filled capsule.
  var knockout: Bool
  /// Content the mark had before a morph, fading out while the new content fades in.
  var outgoing: Outgoing? = nil

  struct Outgoing: Equatable {
    var label: String?
    var icon: String?
    var alpha: CGFloat
    var knockout: Bool
  }
}

struct MenuBarLayout: Equatable {
  var size: CGSize
  var marks: [MenuBarMark]
  var dividers: [CGFloat]

  func workspace(atX x: CGFloat) -> String? {
    marks.first { $0.rect.minX <= x && x <= $0.rect.maxX }?.workspaceID
      ?? marks.min { abs($0.rect.midX - x) < abs($1.rect.midX - x) }
        .flatMap { abs($0.rect.midX - x) <= $0.rect.width / 2 + menuBarSpacing ? $0.workspaceID : nil }
  }
}

private let menuBarHeight: CGFloat = 18
private let menuBarCapsuleHeight: CGFloat = 15
private let menuBarDot: CGFloat = 6
private let menuBarSpacing: CGFloat = 5
private let menuBarGroupGap: CGFloat = 8
@MainActor private let menuBarFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
private let menuBarIconSize: CGFloat = 11

@MainActor
func menuBarLayout(_ monitors: [MenuMonitor], config: MenuBarConfig) -> MenuBarLayout {
  struct Spec { var workspace: MenuWorkspace; var active: Bool; var dim: CGFloat; var label: String?; var icon: String?; var size: CGSize }
  let specs = monitors.map { monitor in
    monitor.workspaces.map { workspace -> Spec in
      let active = workspace.id == monitor.activeWorkspace
      let icon: String? = switch config.workspaceStyle {
      case .icon, .iconAndName: workspace.icon
      case .name, .number, .none: nil
      }
      var label: String? = switch config.workspaceStyle {
      case .name, .iconAndName: workspace.label
      case .icon: icon == nil ? workspace.label : nil
      case .number: String(workspace.position)
      case .none: nil
      }
      // A circle fits one glyph: the icon, else the number.
      if config.indicator == .circle {
        if icon != nil { label = nil } else if label != nil { label = String(workspace.position) }
      }
      let content = menuBarContentWidth(label: label, icon: icon)
      let size: CGSize = switch config.indicator {
      case .dot where !active: CGSize(width: menuBarDot, height: menuBarDot)
      case .circle: CGSize(width: menuBarCapsuleHeight, height: menuBarCapsuleHeight)
      case .box: CGSize(width: max(menuBarCapsuleHeight + 1, content + 10), height: menuBarCapsuleHeight)
      case .dot, .pill: CGSize(width: max(menuBarCapsuleHeight + 5, content + 12), height: menuBarCapsuleHeight)
      }
      return Spec(workspace: workspace, active: active, dim: monitor.isFocused || monitors.count == 1 ? 1 : 0.55,
        label: label, icon: icon, size: size)
    }
  }
  let equalWidth = config.equalWidth && (config.indicator == .box || config.indicator == .pill)
    ? specs.joined().map(\.size.width).max() : nil
  var x: CGFloat = 1
  var marks: [MenuBarMark] = []
  var dividers: [CGFloat] = []
  for (index, group) in specs.enumerated() {
    if index > 0 {
      x += menuBarGroupGap - menuBarSpacing
      dividers.append(x)
      x += menuBarGroupGap
    }
    for spec in group {
      let size = CGSize(width: equalWidth ?? spec.size.width, height: spec.size.height)
      let rect = CGRect(x: x, y: (menuBarHeight - size.height) / 2, width: size.width, height: size.height)
      let empty = spec.workspace.isEmpty
      let filled = config.inactiveStyle == .filled && !(config.indicator == .dot && empty)
      let fill: CGFloat = spec.active ? 1 : filled ? (empty ? 0.25 : 0.5) : 0
      let stroke: CGFloat = spec.active || filled ? 0 : empty ? 0.35 : 0.65
      let content: CGFloat = spec.active || filled ? 1 : empty ? 0.45 : 0.85
      marks.append(MenuBarMark(
        workspaceID: spec.workspace.id, rect: rect,
        radius: config.indicator == .box ? 4 : size.height / 2,
        fill: fill * spec.dim, stroke: stroke * spec.dim, label: spec.label, icon: spec.icon,
        contentAlpha: config.indicator == .dot && !spec.active ? 0 : content * spec.dim,
        knockout: spec.active || filled))
      x += size.width + menuBarSpacing
    }
  }
  return MenuBarLayout(size: CGSize(width: max(x - menuBarSpacing + 1, 2), height: menuBarHeight),
    marks: marks, dividers: dividers)
}

/// Marks present in both layouts move and morph; marks only in `to` appear at their place.
func interpolate(_ from: MenuBarLayout, _ to: MenuBarLayout, _ t: CGFloat) -> MenuBarLayout {
  if t <= 0 { return from }
  if t >= 1 { return to }
  func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
  let sources = Dictionary(from.marks.map { ($0.workspaceID, $0) }, uniquingKeysWith: { a, _ in a })
  let marks = to.marks.map { target -> MenuBarMark in
    guard let source = sources[target.workspaceID] else { return target }
    var contentAlpha = target.contentAlpha < source.contentAlpha
      // A shrinking capsule hides its label before it gets narrower than the text.
      ? source.contentAlpha + (target.contentAlpha - source.contentAlpha) * min(1, t * 2)
      : mix(source.contentAlpha, target.contentAlpha)
    var outgoing: MenuBarMark.Outgoing?
    if source.label != target.label || source.icon != target.icon {
      // New content crossfades in place of the old one instead of swapping inside a moving capsule.
      let fade = min(1, t / 0.35)
      outgoing = MenuBarMark.Outgoing(label: source.label, icon: source.icon,
        alpha: source.contentAlpha * (1 - fade), knockout: source.knockout)
      contentAlpha = target.contentAlpha * max(0, min(1, (t - 0.25) / 0.6))
    }
    return MenuBarMark(
      workspaceID: target.workspaceID,
      rect: CGRect(x: mix(source.rect.minX, target.rect.minX), y: mix(source.rect.minY, target.rect.minY),
        width: mix(source.rect.width, target.rect.width), height: mix(source.rect.height, target.rect.height)),
      radius: mix(source.radius, target.radius),
      fill: mix(source.fill, target.fill), stroke: mix(source.stroke, target.stroke),
      label: target.label, icon: target.icon,
      contentAlpha: contentAlpha,
      knockout: outgoing == nil && source.contentAlpha > 0 && (t < 0.5 || target.contentAlpha == 0)
        ? source.knockout : target.knockout,
      outgoing: outgoing)
  }
  let dividers = from.dividers.count == to.dividers.count
    ? zip(from.dividers, to.dividers).map { mix($0, $1) } : to.dividers
  return MenuBarLayout(size: CGSize(width: mix(from.size.width, to.size.width), height: menuBarHeight),
    marks: marks, dividers: dividers)
}

@MainActor
private func menuBarContentWidth(label: String?, icon: String?) -> CGFloat {
  let iconWidth = icon.flatMap(menuBarSymbol).map(\.size.width) ?? 0
  let labelWidth = label.map { ($0 as NSString).size(withAttributes: [.font: menuBarFont]).width } ?? 0
  return iconWidth + labelWidth + (iconWidth > 0 && labelWidth > 0 ? 3 : 0)
}

@MainActor private var menuBarSymbols: [String: NSImage?] = [:]

/// Unknown symbols, such as one this macOS version lacks, fall back to a grid.
@MainActor
func menuBarSymbol(_ name: String) -> NSImage? {
  if let cached = menuBarSymbols[name] { return cached }
  let configuration = NSImage.SymbolConfiguration(pointSize: menuBarIconSize, weight: .semibold)
  let image = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
    ?? NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil))?
    .withSymbolConfiguration(configuration)
  menuBarSymbols[name] = image
  return image
}

@MainActor
func menuBarImage(_ layout: MenuBarLayout) -> NSImage {
  // Without a known display, for example before Accessibility is granted, the item must stay findable.
  if layout.marks.isEmpty, let placeholder = menuBarSymbol("square.grid.2x2") {
    placeholder.isTemplate = true
    return placeholder
  }
  let image = NSImage(size: layout.size, flipped: false) { _ in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    for x in layout.dividers {
      context.setFillColor(NSColor.black.withAlphaComponent(0.3).cgColor)
      context.fill(CGRect(x: x - 0.5, y: (menuBarHeight - 10) / 2, width: 1, height: 10))
    }
    for mark in layout.marks {
      let radius = min(mark.radius, mark.rect.height / 2)
      if mark.fill > 0 {
        context.setFillColor(NSColor.black.withAlphaComponent(mark.fill).cgColor)
        NSBezierPath(roundedRect: mark.rect, xRadius: radius, yRadius: radius).fill()
      }
      if mark.stroke > 0 {
        context.setStrokeColor(NSColor.black.withAlphaComponent(mark.stroke).cgColor)
        let path = NSBezierPath(roundedRect: mark.rect.insetBy(dx: 0.5, dy: 0.5),
          xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        path.stroke()
      }
      var contents = [(label: mark.label, icon: mark.icon, alpha: mark.contentAlpha, knockout: mark.knockout)]
      if let outgoing = mark.outgoing {
        contents.insert((outgoing.label, outgoing.icon, outgoing.alpha, outgoing.knockout), at: 0)
      }
      for content in contents where content.alpha > 0.01 {
        context.saveGState()
        context.clip(to: mark.rect)
        context.setBlendMode(content.knockout ? .destinationOut : .normal)
        drawMenuBarContent(label: content.label, icon: content.icon, alpha: content.alpha,
          knockout: content.knockout, in: mark.rect)
        context.restoreGState()
      }
    }
    return true
  }
  image.isTemplate = true
  return image
}

@MainActor
private func drawMenuBarContent(label: String?, icon name: String?, alpha: CGFloat, knockout: Bool, in rect: CGRect) {
  let icon = name.flatMap(menuBarSymbol)
  let width = menuBarContentWidth(label: label, icon: name)
  var x = rect.midX - width / 2
  if let icon {
    let iconRect = CGRect(x: x, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
    icon.draw(in: iconRect, from: .zero, operation: knockout ? .destinationOut : .sourceOver, fraction: alpha)
    x += icon.size.width + 3
  }
  if let label {
    let text = NSAttributedString(string: label, attributes: [
      .font: menuBarFont, .foregroundColor: NSColor.black.withAlphaComponent(alpha),
    ])
    let size = text.size()
    text.draw(at: CGPoint(x: x, y: rect.midY - size.height / 2))
  }
}
