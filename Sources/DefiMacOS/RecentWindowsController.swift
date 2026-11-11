import AppKit
import DefiModel

public struct RecentWindowsEntry: Equatable, Sendable {
  public let id: WindowID
  public let title: String
  public let processID: Int32?

  public init(id: WindowID, title: String, processID: Int32?) {
    self.id = id
    self.title = title
    self.processID = processID
  }
}

/// The recent windows switcher: one card per window, a picture when Screen Recording
/// allows it, else the app icon. It never takes focus and shows without animation.
@MainActor
public final class RecentWindowsController {
  static let panelTitle = "Defi recent windows"
  private static let preview = CGSize(width: 176, height: 110)
  private static let cardSize = CGSize(width: preview.width + 16, height: preview.height + 40)
  private static let spacing: CGFloat = 8
  private static let inset: CGFloat = 14

  private var panel: NSPanel?
  private var cards: [RecentWindowCard] = []
  private var shown: (entries: [RecentWindowsEntry], monitorID: MonitorID?, previews: Bool)?

  public init() {}

  public var isVisible: Bool { panel != nil }

  public func show(
    _ entries: [RecentWindowsEntry], selection: Int, on monitorID: MonitorID?, previews: Bool
  ) {
    guard !entries.isEmpty else { return close() }
    let previews = previews && CGPreflightScreenCaptureAccess()
    if panel == nil || shown?.entries != entries || shown?.monitorID != monitorID
      || shown?.previews != previews
    {
      build(entries, on: monitorID, previews: previews)
    }
    for (index, card) in cards.enumerated() { card.isSelected = index == selection }
    if cards.indices.contains(selection) {
      cards[selection].scrollToVisible(cards[selection].bounds.insetBy(dx: -Self.inset, dy: 0))
    }
  }

  public func close() {
    panel?.close()
    panel = nil
    cards = []
    shown = nil
  }

  private func build(_ entries: [RecentWindowsEntry], on monitorID: MonitorID?, previews: Bool) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint64Value == monitorID?.rawValue
    }) ?? NSScreen.main else { return }
    close()
    shown = (entries, monitorID, previews)
    let count = CGFloat(entries.count)
    let contentWidth = count * Self.cardSize.width + (count - 1) * Self.spacing + 2 * Self.inset
    let bounds = screen.visibleFrame
    let size = CGSize(
      width: min(contentWidth, bounds.width - 96), height: Self.cardSize.height + 2 * Self.inset)
    let frame = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
    // With a screen, the content rect is relative to that screen's origin.
    let panel = RecentWindowsPanel(
      contentRect: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
    panel.title = Self.panelTitle
    panel.setAccessibilityLabel("Recent windows")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

    let background = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 20
    background.layer?.masksToBounds = true

    let document = NSView(frame: CGRect(
      x: 0, y: 0, width: max(contentWidth, size.width), height: size.height))
    let leading = max(Self.inset, (size.width - contentWidth) / 2 + Self.inset)
    cards = entries.enumerated().map { index, entry in
      let card = RecentWindowCard(
        entry: entry, previews: previews, preview: Self.preview,
        frame: CGRect(
          x: leading + CGFloat(index) * (Self.cardSize.width + Self.spacing), y: Self.inset,
          width: Self.cardSize.width, height: Self.cardSize.height))
      document.addSubview(card)
      return card
    }
    let scrollView = NSScrollView(frame: background.bounds)
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = false
    scrollView.documentView = document
    background.addSubview(scrollView)
    panel.contentView = background
    self.panel = panel
    panel.orderFrontRegardless()
  }
}

private final class RecentWindowsPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class RecentWindowCard: NSView {
  var isSelected = false {
    didSet {
      guard isSelected != oldValue else { return }
      layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor : nil
      layer?.borderWidth = isSelected ? 2 : 0
      setAccessibilitySelected(isSelected)
    }
  }

  init(entry: RecentWindowsEntry, previews: Bool, preview: CGSize, frame: CGRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    let application = entry.processID.flatMap { NSRunningApplication(processIdentifier: $0) }
    let title = entry.title.isEmpty ? application?.localizedName ?? "" : entry.title
    let previewFrame = CGRect(
      x: (frame.width - preview.width) / 2, y: frame.height - 8 - preview.height,
      width: preview.width, height: preview.height)
    let picture = previews ? WindowCaptureStore.shared.picture(entry.id) : nil
    let icon = NSImageView(image: application?.icon ?? NSImage())
    if let picture {
      let layer = CALayer()
      layer.frame = previewFrame
      layer.contents = picture.contents
      layer.contentsGravity = .resizeAspect
      self.layer?.addSublayer(layer)
      icon.frame = CGRect(x: previewFrame.minX + 4, y: previewFrame.minY + 4, width: 32, height: 32)
    } else {
      icon.frame = CGRect(x: previewFrame.midX - 32, y: previewFrame.midY - 32, width: 64, height: 64)
    }
    addSubview(icon)
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.frame = CGRect(x: 6, y: 8, width: frame.width - 12, height: 18)
    addSubview(label)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    let appName = application?.localizedName ?? ""
    setAccessibilityLabel(appName.isEmpty || appName == title ? title : "\(title), \(appName)")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }
}
