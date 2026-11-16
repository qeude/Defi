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

let nativeFullscreenPlaceholderHint = "Press Return to open"

@MainActor
final class NativeFullscreenPlaceholderManager {
  private var panels: [WindowID: NativeFullscreenPlaceholderPanel] = [:]
  var activationHandler: ((WindowID) -> Void)?

  private var anchors: [MonitorID: NSPanel] = [:]
  private var suppressedMonitorIDs: Set<MonitorID> = []
  private var fullscreenWindowIDs: Set<WindowID> = []
  private var selectedPlaceholderID: WindowID?
  private var pendingKey: (windowID: WindowID, requestedAt: TimeInterval)?
  private var keyObservers: [NSObjectProtocol] = []

  /// The selected placeholder takes the keyboard, so Return reaches it instead of the window left behind.
  func focus(_ windowID: WindowID) {
    // Without a handler Return opens nothing.
    guard activationHandler != nil else { return }
    // On its own Space, a refocus must not pull the user out, nor let an older request do it.
    guard monitorsShowingFullscreenSpace([windowID]).isEmpty else {
      pendingKey = nil
      return
    }
    pendingKey = (windowID, ProcessInfo.processInfo.systemUptime)
    if keyObservers.isEmpty {
      // AX activation lands asynchronously, and a Space switch reactivates the desktop's last
      // app, so the panel takes the keyboard again once either settles.
      keyObservers = [
        NotificationCenter.default.addObserver(
          forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keyPendingPanel() } },
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.keyPendingPanel() } },
      ]
    }
    keyPendingPanel()
  }

  private func keyPendingPanel() {
    guard let pending = pendingKey,
      ProcessInfo.processInfo.systemUptime - pending.requestedAt < 2
    else {
      pendingKey = nil
      return
    }
    if !NSApplication.shared.isActive {
      // Cooperative activate() reports success even when refused; AX frontmost takes effect.
      AXUIElementSetAttributeValue(
        AXUIElementCreateApplication(getpid()), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
    let away = monitorsAwayFromDesktop(Set(anchors.keys).union(panels.values.map(\.monitorID)))
    // Only a fullscreen window really on screen sends Defi back through the anchor; a mismatch
    // alone is a switch in progress, or an anchor left on a fullscreen Space.
    let showing = monitorsShowingFullscreenSpace(fullscreenWindowIDs)
    let panel = panels[pending.windowID]
    if let panel, !away.contains(panel.monitorID) {
      // Back from a fullscreen Space, the desktop is active from the start of the slide:
      // a target off screen until now shows during it instead of after.
      panel.orderIn()
      panel.makeKey()
      if NSApplication.shared.isActive, panel.isKey { pendingKey = nil }
    } else if let monitorID = panel?.monitorID ?? showing.first, showing.contains(monitorID),
      let anchor = anchors[monitorID]
    {
      // The strip is hidden behind a fullscreen Space; fronting the desktop anchor switches back.
      // Only once Defi is active: otherwise the switch reactivates the desktop's last app.
      // And once the target has its panel in the strip, so the desktop slides in laid out.
      if NSApplication.shared.isActive, panels[pending.windowID] != nil {
        anchor.makeKeyAndOrderFront(nil)
      }
    }
    // Activation and Space switches land in no fixed order: try again until the panel holds the keyboard.
    guard pendingKey != nil, !retryScheduled else { return }
    retryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      MainActor.assumeIsolated {
        self?.retryScheduled = false
        self?.keyPendingPanel()
      }
    }
  }
  private var retryScheduled = false

  /// Monitors that may be showing a fullscreen Space now. Mid-switch, the desktop anchor still
  /// reads as on the active Space while the fullscreen window is already on screen, and the
  /// reverse on the way back: either one means a panel ordered now could land there.
  private func monitorsAwayFromDesktop(_ monitorIDs: Set<MonitorID>) -> Set<MonitorID> {
    let showing = monitorsShowingFullscreenSpace(fullscreenWindowIDs)
    let now = ProcessInfo.processInfo.systemUptime
    for (monitorID, anchor) in anchors {
      guard !showing.contains(monitorID), !anchor.isOnActiveSpace else {
        anchorMismatchSince[monitorID] = nil
        continue
      }
      // No fullscreen window shows, yet the anchor is off the active Space for longer than any
      // switch takes: it was ordered in on a fullscreen Space. Order it in again on the desktop.
      let since = anchorMismatchSince[monitorID] ?? now
      anchorMismatchSince[monitorID] = since
      if now - since > 1 {
        anchor.orderOut(nil)
        anchor.orderBack(nil)
        anchorMismatchSince[monitorID] = nil
      }
    }
    return monitorIDs.filter { anchors[$0].map { !$0.isOnActiveSpace } == true || showing.contains($0) }
  }
  private var anchorMismatchSince: [MonitorID: TimeInterval] = [:]

  private func ensureAnchor(on monitorID: MonitorID, screen: NSScreen?) {
    guard anchors[monitorID] == nil, let screen else { return }
    let anchor = KeyPanel(
      contentRect: CGRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1),
      // Activating, so the Space switch it causes keeps Defi active instead of the desktop's last app.
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    anchor.isOpaque = false
    anchor.backgroundColor = .clear
    anchor.ignoresMouseEvents = true
    anchor.hasShadow = false
    anchor.collectionBehavior = [.ignoresCycle]
    anchor.hidesOnDeactivate = false
    anchor.isReleasedWhenClosed = false
    anchor.isExcludedFromWindowsMenu = true
    anchor.animationBehavior = .none
    // macOS may hand the keyboard back to the anchor after a switch: Return there still opens
    // the selected placeholder, and other keys are dropped as on the placeholder itself.
    anchor.onActivate = { [weak self] in
      guard let self, let windowID = self.selectedPlaceholderID else { return }
      self.activationHandler?(windowID)
    }
    // Ordered in once from the desktop and never out, it stays on that Space.
    anchor.orderBack(nil)
    anchors[monitorID] = anchor
  }

  var visibleWindowIDs: Set<WindowID> {
    Set(panels.compactMap { $0.value.isVisible ? $0.key : nil })
  }

  var transparentSurfaceWindowIDs: Set<CGWindowID> {
    Set(panels.values.compactMap { $0.isVisible ? $0.windowID : nil })
      .union(anchors.values.compactMap { $0.windowNumber > 0 ? CGWindowID($0.windowNumber) : nil })
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
    suppressedMonitorIDs: Set<MonitorID> = [],
    fullscreenWindowIDs: Set<WindowID> = [],
    accentColor: UInt32
  ) -> Bool {
    self.fullscreenWindowIDs = fullscreenWindowIDs
    // The daemon learns of a Space switch a beat late, and a panel or anchor ordered in
    // meanwhile lands on the fullscreen Space: where an anchor exists it answers instead.
    let monitorIDs = Set(placeholders.map(\.monitorID))
    let suppressedMonitorIDs = monitorsAwayFromDesktop(monitorIDs)
      .union(suppressedMonitorIDs.filter { anchors[$0] == nil })
    let desiredWindowIDs = Set(placeholders.map(\.windowID))
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
        panel = NativeFullscreenPlaceholderPanel(placeholder: placeholder) { [weak self] in
          self?.activationHandler?(placeholder.windowID)
        }
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
      if !suppressedMonitorIDs.contains(placeholder.monitorID) {
        ensureAnchor(on: placeholder.monitorID, screen: panel.screen)
      }
    }
    self.suppressedMonitorIDs = suppressedMonitorIDs
    selectedPlaceholderID = selectedWindowID.flatMap { panels[$0] == nil ? nil : $0 }
    WindowCaptureCache.shared.setFullscreenDisplays(
      Set(suppressedMonitorIDs.compactMap { CGDirectDisplayID(exactly: $0.rawValue) }))
    if pendingKey != nil, pendingKey?.windowID != selectedWindowID { pendingKey = nil }
    if pendingKey != nil { keyPendingPanel() }
    return surfacesChanged
  }

  func hide() {
    for panel in panels.values {
      panel.close()
    }
    panels.removeAll(keepingCapacity: true)
    anchors.values.forEach { $0.close() }
    anchors.removeAll()
  }
}

/// Monitors whose active Space is one of these fullscreen windows' Spaces.
func monitorsShowingFullscreenSpace(_ windowIDs: Set<WindowID>) -> Set<MonitorID> {
  guard !windowIDs.isEmpty else { return [] }
  let infos = ribbonProxyWindowDescriptions(windowIDs.compactMap { CGWindowID(exactly: $0.rawValue) })
  return Set(infos.compactMap { info -> MonitorID? in
    guard (info[kCGWindowIsOnscreen as String] as? Bool) == true,
      let bounds = info[kCGWindowBounds as String] as? [String: Any],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
    var display: CGDirectDisplayID = 0, count: UInt32 = 0
    guard CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count) == .success,
      count == 1 else { return nil }
    return MonitorID(rawValue: UInt64(display))
  })
}

@MainActor
private final class NativeFullscreenPlaceholderPanel {
  private let panel: KeyPanel
  private let placeholderView: NativeFullscreenPlaceholderView
  private var placeholder: NativeFullscreenPlaceholder
  private var stackingWindowID: WindowID?
  private var orderedIn = false

  var isVisible: Bool { orderedIn }

  var windowID: CGWindowID? {
    panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
  }

  init(placeholder: NativeFullscreenPlaceholder, onActivate: @escaping () -> Void) {
    self.placeholder = placeholder
    placeholderView = NativeFullscreenPlaceholderView(
      appID: placeholder.appID,
      title: placeholder.title
    )
    panel = KeyPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.onActivate = onActivate
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.sharingType = .readOnly
    panel.level = .normal
    // Not on all Spaces: that includes fullscreen ones. Sync orders it in only from the desktop.
    panel.collectionBehavior = [.ignoresCycle]
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
    let wasVisible = isVisible
    let target = appKitRect(for: placeholder.frame)
    if panel.frame != target { panel.setFrame(target, display: false) }
    if self.placeholder.appID != placeholder.appID
      || self.placeholder.title != placeholder.title
    {
      placeholderView.update(appID: placeholder.appID, title: placeholder.title)
    }
    placeholderView.updateAppearance(selected: selected, accentColor: accentColor)
    self.placeholder = placeholder
    desiredStackingWindowID = stackingWindowID
    // While a fullscreen Space shows, nothing is ordered in: it would land there. Panels
    // already in stay on the desktop, out of sight, ready for the way back; ordering them out
    // mid-switch showed the wallpaper in their slots.
    if suppressed { return false }
    if !orderedIn || self.stackingWindowID != stackingWindowID {
      if let stackingWindowID {
        panel.order(.below, relativeTo: Int(stackingWindowID.rawValue))
      } else {
        panel.orderBack(nil)
      }
      self.stackingWindowID = stackingWindowID
      orderedIn = true
    }
    return isVisible != wasVisible
  }

  var isKey: Bool { panel.isKeyWindow }
  var monitorID: MonitorID { placeholder.monitorID }
  var screen: NSScreen? { panel.screen }

  private var desiredStackingWindowID: WindowID?

  func orderIn() {
    guard !orderedIn else { return }
    if let desiredStackingWindowID {
      panel.order(.below, relativeTo: Int(desiredStackingWindowID.rawValue))
    } else {
      panel.orderBack(nil)
    }
    stackingWindowID = desiredStackingWindowID
    orderedIn = true
  }

  func makeKey() {
    guard orderedIn else { return }
    panel.makeKey()
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

/// Takes keys without activating Defi: Return opens the fullscreen window, every other key is dropped.
private final class KeyPanel: NSPanel {
  var onActivate: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 { onActivate?() }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
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
    setAccessibilityHelp(selected ? nativeFullscreenPlaceholderHint : nil)
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
  let hint = NSAttributedString(string: selected ? nativeFullscreenPlaceholderHint : "",
    attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
      .paragraphStyle: paragraph])
  let textWidth = max(size.width - 48, 0)
  let nameHeight = ceil(name.size().height), statusHeight = ceil(status.size().height)
  let hintHeight = selected ? ceil(hint.size().height) : 0
  let spacing: CGFloat = 8, iconSide: CGFloat = 80
  var y = ((size.height + iconSide + spacing + nameHeight + spacing + statusHeight
    + (selected ? spacing + hintHeight : 0)) / 2).rounded()
  y -= iconSide
  icon?.draw(in: CGRect(x: ((size.width - iconSide) / 2).rounded(), y: y, width: iconSide, height: iconSide))
  y -= spacing + nameHeight
  name.draw(with: CGRect(x: 24, y: y, width: textWidth, height: nameHeight),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  y -= spacing + statusHeight
  status.draw(with: CGRect(x: 24, y: y, width: textWidth, height: statusHeight),
    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  if selected {
    y -= spacing + hintHeight
    hint.draw(with: CGRect(x: 24, y: y, width: textWidth, height: hintHeight),
      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
  }
  return context.makeImage()
}
