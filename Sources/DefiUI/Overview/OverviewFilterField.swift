import AppKit
import DefiMacOS

/// The type-to-filter query, or a hint that typing filters while it is empty. The Overview panel
/// never becomes key, so this is a label the controller fills, not an editable field.
@MainActor
final class OverviewFilterField: NSView {
  static let height: CGFloat = 36
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "Type to filter")
  private let count = NSTextField(labelWithString: "")
  private let content = NSView()
  private var glass: NSView?
  private var shown = true
  /// Sized to the query rather than the band.
  var compact = false

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // Above the Overview's canvas and band, which the view adds as sibling sublayers.
    layer?.zPosition = 1_000
    if #available(macOS 26, *) {
      let glass = NSGlassEffectView()
      glass.cornerRadius = Self.height / 2
      glass.contentView = content
      addSubview(glass)
      self.glass = glass
    } else {
      layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.6).cgColor
      layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
      layer?.borderWidth = 0.5
      layer?.cornerRadius = Self.height / 2
      layer?.cornerCurve = .continuous
      addSubview(content)
    }
    appearance = NSAppearance(named: .darkAqua)
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.lineBreakMode = .byTruncatingHead
    count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    count.textColor = .tertiaryLabelColor
    for view in [icon, label, count] { content.addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Filter")
    setAccessibilityHelp("Type to filter windows")
    update(query: "", matchCount: 0)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  // A click on the field must not reach the card or desktop beneath it.
  override func mouseDown(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}
  override func rightMouseDown(with event: NSEvent) {}

  override var fittingSize: NSSize {
    let text = min(ceil(label.cell?.cellSize.width ?? 0), 280)
    return NSSize(width: max(34 + text + countWidth + 12, compact ? 120 : 360), height: Self.height)
  }

  private var countWidth: CGFloat {
    count.stringValue.isEmpty ? 0 : 10 + countSize.width
  }

  // The cell's size, not the intrinsic one, which is a point short and truncates the text.
  private var countSize: NSSize {
    let size = count.cell?.cellSize ?? .zero
    return NSSize(width: ceil(size.width), height: ceil(size.height))
  }

  override func layout() {
    super.layout()
    glass?.frame = bounds
    content.frame = bounds
    icon.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
    count.frame = NSRect(x: bounds.width - 12 - countSize.width, y: (bounds.height - countSize.height) / 2,
      width: countSize.width, height: countSize.height)
    let labelHeight = label.intrinsicContentSize.height
    label.frame = NSRect(x: 34, y: (bounds.height - labelHeight) / 2,
      width: max(bounds.width - 12 - countWidth - 34, 0), height: labelHeight)
  }

  func update(query: String, matchCount: Int) {
    label.stringValue = query.isEmpty ? "Type to filter" : query
    label.textColor = query.isEmpty ? .secondaryLabelColor : .labelColor
    icon.contentTintColor = query.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
    count.stringValue = query.isEmpty ? "" : matchCount == 0 ? "No matches" : "\(matchCount)"
    setAccessibilityValue(query)
    needsLayout = true
  }

  func setShown(_ show: Bool, animated: Bool) {
    guard show != shown else { return }
    shown = show
    guard animated else {
      alphaValue = show ? 1 : 0
      isHidden = !show
      return
    }
    isHidden = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = show ? overviewTransitionDuration : overviewSelectionFadeDuration
      context.timingFunction = overviewEaseOut
      animator().alphaValue = show ? 1 : 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.shown else { return }
        self.isHidden = true
      }
    }
  }
}
