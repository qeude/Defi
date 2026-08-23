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
    panel.collectionBehavior = [
      .ignoresCycle,
    ]
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
  private let iconView = NSImageView()
  private let appLabel = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "macOS Full Screen")
  private var selected: Bool?
  private var accentColor: UInt32?

  init(appID: String, title: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor(
      srgbRed: 15 / 255,
      green: 15 / 255,
      blue: 20 / 255,
      alpha: 1
    ).cgColor
    layer?.cornerRadius = 10
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
    layer?.masksToBounds = true

    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    appLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    appLabel.textColor = .white
    appLabel.alignment = .center
    appLabel.lineBreakMode = .byTruncatingTail
    statusLabel.font = .systemFont(ofSize: 12, weight: .regular)
    statusLabel.textColor = NSColor.white.withAlphaComponent(0.68)
    statusLabel.alignment = .center

    let stack = NSStackView(views: [iconView, appLabel, statusLabel])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: 80),
      iconView.heightAnchor.constraint(equalToConstant: 80),
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
      appLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
      statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
    ])
    update(appID: appID, title: title)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  func update(appID: String, title: String) {
    let application = NSRunningApplication.runningApplications(
      withBundleIdentifier: appID
    ).first
    let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: appID
    )
    let appName = application?.localizedName
      ?? applicationURL?.deletingPathExtension().lastPathComponent
      ?? appID
    iconView.image = application?.icon
      ?? applicationURL.map {
        NSWorkspace.shared.icon(forFile: $0.path)
      }
      ?? NSImage(named: NSImage.applicationIconName)
    appLabel.stringValue = title.isEmpty ? appName : title
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
    guard self.selected != selected || self.accentColor != accentColor else {
      return
    }
    self.selected = selected
    self.accentColor = accentColor
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer?.borderWidth = selected ? 2 : 1
    layer?.borderColor = selected
      ? NSColor(
        srgbRed: CGFloat((accentColor >> 16) & 0xff) / 255,
        green: CGFloat((accentColor >> 8) & 0xff) / 255,
        blue: CGFloat(accentColor & 0xff) / 255,
        alpha: 1
      ).cgColor
      : NSColor.white.withAlphaComponent(0.14).cgColor
    CATransaction.commit()
  }
}
