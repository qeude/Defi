import AppKit

/// The type-to-filter query, shown only while it is not empty. The Overview panel never
/// becomes key, so this is a label the controller fills, not an editable field.
@MainActor
final class OverviewFilterField: NSView {
  private let background = NSVisualEffectView()
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let count = NSTextField(labelWithString: "")
  private var shown = false

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    // Above the Overview's canvas, which the view adds as a sibling sublayer.
    layer?.zPosition = 1_000
    appearance = NSAppearance(named: .darkAqua)
    alphaValue = 0
    isHidden = true
    background.material = .hudWindow
    background.blendingMode = .withinWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 15
    background.layer?.masksToBounds = true
    icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    icon.contentTintColor = .secondaryLabelColor
    label.font = .systemFont(ofSize: 15, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingHead
    count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    count.textColor = .tertiaryLabelColor
    for view in [background, icon, label, count] { addSubview(view) }
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Filter")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  override var fittingSize: NSSize {
    let text = min(label.intrinsicContentSize.width, 280)
    return NSSize(width: max(34 + text + 10 + count.intrinsicContentSize.width + 12, 120), height: 30)
  }

  override func layout() {
    super.layout()
    background.frame = bounds
    icon.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: 16, height: 16)
    let countSize = count.intrinsicContentSize
    count.frame = NSRect(x: bounds.width - 12 - countSize.width, y: (bounds.height - countSize.height) / 2,
      width: countSize.width, height: countSize.height)
    let labelHeight = label.intrinsicContentSize.height
    label.frame = NSRect(x: 34, y: (bounds.height - labelHeight) / 2,
      width: max(count.frame.minX - 10 - 34, 0), height: labelHeight)
  }

  func update(query: String, matchCount: Int, animated: Bool) {
    if !query.isEmpty {
      label.stringValue = query
      count.stringValue = matchCount == 0 ? "No matches" : "\(matchCount)"
      setAccessibilityValue(query)
      needsLayout = true
    }
    let show = !query.isEmpty
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
