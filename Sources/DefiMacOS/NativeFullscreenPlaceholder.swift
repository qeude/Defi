import AppKit
import DefiModel
import QuartzCore

public struct NativeFullscreenPlaceholder: Equatable, Sendable {
  public let windowID: WindowID
  public let monitorID: MonitorID
  public let appID: String
  public let title: String
  public let frame: Rect

  public init(
    windowID: WindowID,
    monitorID: MonitorID,
    appID: String,
    title: String,
    frame: Rect
  ) {
    self.windowID = windowID
    self.monitorID = monitorID
    self.appID = appID
    self.title = title
    self.frame = frame
  }
}

@MainActor
final class NativeFullscreenPlaceholderManager {
  private var panels: [WindowID: NativeFullscreenPlaceholderPanel] = [:]

  var visibleWindowIDs: Set<WindowID> {
    Set(panels.compactMap { $0.value.isVisible ? $0.key : nil })
  }

  var transparentSurfaceWindowIDs: Set<CGWindowID> {
    Set(panels.values.compactMap { $0.isVisible ? $0.windowID : nil })
  }

  var ownedSurfaceWindowID: WindowID? {
    transparentSurfaceWindowIDs.first.map {
      WindowID(rawValue: UInt64($0))
    }
  }

  @discardableResult
  func sync(
    _ placeholders: [NativeFullscreenPlaceholder],
    selectedWindowID: WindowID?,
    stackingWindowID: WindowID?,
    suppressedWindowIDs: Set<WindowID> = [],
    accentColor: UInt32
  ) -> Bool {
    let desiredWindowIDs = Set(placeholders.map(\.windowID))
    let suppressedMonitorIDs = Set(placeholders.compactMap {
      suppressedWindowIDs.contains($0.windowID) ? $0.monitorID : nil
    })
    let removedWindowIDs = panels.keys.filter {
      !desiredWindowIDs.contains($0)
    }
    for windowID in removedWindowIDs {
      panels.removeValue(forKey: windowID)?.close()
    }

    var surfacesChanged = !removedWindowIDs.isEmpty
    for placeholder in placeholders {
      let panel: NativeFullscreenPlaceholderPanel
      if let existing = panels[placeholder.windowID] {
        panel = existing
      } else {
        panel = NativeFullscreenPlaceholderPanel(placeholder: placeholder)
        surfacesChanged = true
      }
      panels[placeholder.windowID] = panel
      surfacesChanged = panel.sync(
        placeholder,
        selected: placeholder.windowID == selectedWindowID,
        stackingWindowID: stackingWindowID,
        suppressed: suppressedMonitorIDs.contains(placeholder.monitorID),
        accentColor: accentColor
      ) || surfacesChanged
    }
    return surfacesChanged
  }

  func hide() {
    for panel in panels.values {
      panel.close()
    }
    panels.removeAll(keepingCapacity: true)
  }
}

@MainActor
private final class NativeFullscreenPlaceholderPanel {
  private let panel: NSPanel
  private let placeholderView: NativeFullscreenPlaceholderView
  private var placeholder: NativeFullscreenPlaceholder
  private var stackingWindowID: WindowID?
  private var orderedIn = false

  var isVisible: Bool { orderedIn }

  var windowID: CGWindowID? {
    panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
  }

  init(placeholder: NativeFullscreenPlaceholder) {
    self.placeholder = placeholder
    placeholderView = NativeFullscreenPlaceholderView(
      appID: placeholder.appID,
      title: placeholder.title
    )
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.sharingType = .readOnly
    panel.level = .normal
    // Like the borders: ordered in while the fullscreen Space is active, it would stay there.
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.contentView = placeholderView
  }

  func sync(
    _ placeholder: NativeFullscreenPlaceholder,
    selected: Bool,
    stackingWindowID: WindowID?,
    suppressed: Bool,
    accentColor: UInt32
  ) -> Bool {
    let wasOrderedIn = orderedIn
    if self.placeholder.frame != placeholder.frame {
      panel.setFrame(appKitRect(for: placeholder.frame), display: false)
    } else if !orderedIn {
      panel.setFrame(appKitRect(for: placeholder.frame), display: false)
    }
    if self.placeholder.appID != placeholder.appID
      || self.placeholder.title != placeholder.title
    {
      placeholderView.update(appID: placeholder.appID, title: placeholder.title)
    }
    placeholderView.updateAppearance(
      selected: selected,
      accentColor: accentColor
    )
    self.placeholder = placeholder
    if suppressed {
      panel.orderOut(nil)
      self.stackingWindowID = stackingWindowID
      orderedIn = false
      return wasOrderedIn
    }
    if !orderedIn || self.stackingWindowID != stackingWindowID {
      if let stackingWindowID {
        panel.order(.below, relativeTo: Int(stackingWindowID.rawValue))
      } else {
        panel.orderBack(nil)
      }
      self.stackingWindowID = stackingWindowID
      orderedIn = true
    }
    return orderedIn != wasOrderedIn
  }

  func close() {
    panel.orderOut(nil)
    panel.close()
  }

  private func appKitRect(for frame: Rect) -> CGRect {
    let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(
      x: frame.x,
      y: mainTop - frame.y - frame.height,
      width: frame.width,
      height: frame.height
    )
  }
}

@MainActor
private final class NativeFullscreenPlaceholderView: NSView {
  private var appID: String
  private var title: String
  private var selected = false
  private var accentColor: UInt32 = 0

  init(appID: String, title: String) {
    self.appID = appID
    self.title = title
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    update(appID: appID, title: title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override var wantsUpdateLayer: Bool { true }

  // The same picture the overlay carries during motions, so the handoff is invisible.
  override func updateLayer() {
    layer?.contents = nativeFullscreenPlaceholderImage(appID: appID, title: title, size: bounds.size,
      scale: window?.backingScaleFactor ?? 2, selected: selected, accentColor: accentColor)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsDisplay = true
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }

  func update(appID: String, title: String) {
    self.appID = appID
    self.title = title
    needsDisplay = true
    let appName = nativeFullscreenPlaceholderAppName(appID)
    toolTip = title.isEmpty ? appName : title
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel(
      title.isEmpty
        ? "\(appName), macOS Full Screen"
        : "\(appName), \(title), macOS Full Screen"
    )
  }

  func updateAppearance(selected: Bool, accentColor: UInt32) {
    guard self.selected != selected || self.accentColor != accentColor else { return }
    self.selected = selected
    self.accentColor = accentColor
    needsDisplay = true
  }
}

private func nativeFullscreenPlaceholderAppName(_ appID: String) -> String {
  NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID)?
      .deletingPathExtension().lastPathComponent
    ?? appID
}

/// The placeholder card: drawn by Defi, so the overlay never needs to capture it.
func nativeFullscreenPlaceholderImage(appID: String, title: String, size: CGSize, scale: CGFloat,
  selected: Bool, accentColor: UInt32) -> CGImage? {
  let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
  guard width > 0, height > 0,
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
  else { return nil }
  context.scaleBy(x: scale, y: scale)
  let previous = NSGraphicsContext.current
  NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
  defer { NSGraphicsContext.current = previous }

  let bounds = CGRect(origin: .zero, size: size)
  let borderWidth: CGFloat = selected ? 2 : 1
  NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 20 / 255, alpha: 1).setFill()
  NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
  let border = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
    xRadius: 10 - borderWidth / 2, yRadius: 10 - borderWidth / 2)
  border.lineWidth = borderWidth
  (selected
    ? NSColor(srgbRed: CGFloat((accentColor >> 16) & 0xff) / 255, green: CGFloat((accentColor >> 8) & 0xff) / 255,
      blue: CGFloat(accentColor & 0xff) / 255, alpha: 1)
    : NSColor.white.withAlphaComponent(0.14)).setStroke()
  border.stroke()

  let application = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first
  let icon = application?.icon
    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: appID).map {
      NSWorkspace.shared.icon(forFile: $0.path)
    }
    ?? NSImage(named: NSImage.applicationIconName)
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  paragraph.lineBreakMode = .byTruncatingTail
  let name = NSAttributedString(string: title.isEmpty ? nativeFullscreenPlaceholderAppName(appID) : title,
    attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.white,
      .paragraphStyle: paragraph])
  let status = NSAttributedString(string: "macOS Full Screen",
    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white.withAlphaComponent(0.68),
      .paragraphStyle: paragraph])
  let textWidth = max(size.width - 48, 0)
  let nameHeight = ceil(name.size().height), statusHeight = ceil(status.size().height)
  let spacing: CGFloat = 8, iconSide: CGFloat = 80
  var y = ((size.height + iconSide + spacing + nameHeight + spacing + statusHeight) / 2).rounded()
  y -= iconSide
  icon?.draw(in: CGRect(x: ((size.width - iconSide) / 2).rounded(), y: y, width: iconSide, height: iconSide))
  y -= spacing + nameHeight
  name.draw(with: CGRect(x: 24, y: y, width: textWidth, height: nameHeight),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  y -= spacing + statusHeight
  status.draw(with: CGRect(x: 24, y: y, width: textWidth, height: statusHeight),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  return context.makeImage()
}
