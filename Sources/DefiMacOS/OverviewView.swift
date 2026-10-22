import AppKit
import DefiConfig
import DefiCore
import DefiModel
import QuartzCore

// The overview is a retained layer tree: a refresh moves existing textures and the
// compositor blends them, so no frame rasterizes the panel on the main thread.
@MainActor
final class OverviewView: NSView {
  let monitorID: MonitorID
  private weak var delegate: OverviewViewDelegate?
  private var snapshot: OverviewSnapshot?
  private var projection: OverviewProjection?
  private var selection: OverviewSelection?
  private var drag: OverviewDragPresentation?
  private var borderStyle = WindowBorderStyle(config: BordersConfig())
  private var windowCornerRadius = 12.0
  private(set) var desktopImage: NSImage?
  // Cross-fades the wallpaper on the next render; Core Animation runs the fade.
  private var desktopFadeDuration: TimeInterval = 0
  var hasDesktopImage: Bool { desktopImage != nil }
  private var previews: [WindowID: NSImage] = [:]
  var surfaceWindowIDs = Set<WindowID>() {
    didSet { if oldValue != surfaceWindowIDs { needsDisplay = true } }
  }
  var suppressedSurfaceWindowIDs = Set<WindowID>() {
    didSet { if oldValue != suppressedSurfaceWindowIDs { needsDisplay = true } }
  }
  private var previewOpacities: [WindowID: Double] = [:]
  // Image being replaced, kept underneath until the new preview finishes fading in.
  private var outgoingPreviews: [WindowID: NSImage] = [:]
  private var mouseDownPoint: NSPoint?
  private var mouseDownWindowID: WindowID?
  private var mouseDownOverflow: (workspaceID: WorkspaceID, direction: Int)?
  private var leftDragStarted = false
  private var rightDragPoint: NSPoint?
  private var iconCache: [String: NSImage] = [:]
  private let titleScrimImage = overviewLabelBitmap(size: CGSize(width: 1, height: 128), scale: 1) {
      NSGradient(
        colorsAndLocations:
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0, opacity: 1)
          ), 0),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.25, opacity: 1)
          ), 0.25),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.5, opacity: 1)
          ), 0.5),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.75, opacity: 1)
          ), 0.75),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.9, opacity: 1)
          ), 0.9),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.97, opacity: 1)
          ), 0.97),
          (NSColor.clear, 1)
      )?.draw(
        from: NSPoint(x: 0.5, y: 0),
        to: NSPoint(x: 0.5, y: 128),
        options: []
      )
  }
  private let titleCache = OverviewTitleCache()
  var titleRasterizationCount: Int { titleCache.rasterizationCount }
  private var labelImages: [String: NSImage] = [:]
  private(set) var presentationUpdateCount = 0
  private(set) var renderCount = 0

  private let canvas = CALayer()
  private var workspaceLayers: [WorkspaceID: OverviewWorkspaceLayers] = [:]
  private var cardLayers: [WindowID: OverviewCardLayers] = [:]
  private var borderLayers: [WindowID: CALayer] = [:]
  private let overlayLayer = CALayer()
  private let dragLayer = CALayer()
  private let dragBorder = CALayer()
  private let dragTitle = CATextLayer()
  private let dropBand = CALayer()
  private let dropLine = CALayer()

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  init(monitorID: MonitorID, delegate: OverviewViewDelegate) {
    self.monitorID = monitorID
    self.delegate = delegate
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    dragLayer.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.94).cgColor
    dragBorder.borderWidth = 3
    dragTitle.isWrapped = true
    dragLayer.addSublayer(dragBorder)
    dragLayer.addSublayer(dragTitle)
    dropBand.cornerRadius = 10
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Defi Overview")
  }

  func discardPreviewImages() {
    previews.removeAll(keepingCapacity: false)
    outgoingPreviews.removeAll(keepingCapacity: false)
    previewOpacities.removeAll()
    titleCache.prune(windowIDs: [])
    iconCache.removeAll()
    // Layers retain their textures; dropping them releases the images with the caches.
    for card in cardLayers.values { card.root.removeFromSuperlayer() }
    cardLayers.removeAll()
    needsDisplay = true
  }

  func setDesktopImage(_ image: NSImage?, fadeDuration: TimeInterval = 0) {
    desktopFadeDuration = desktopImage != nil && image != nil ? fadeDuration : 0
    desktopImage = image
    needsDisplay = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  @discardableResult
  func update(
    snapshot: OverviewSnapshot,
    projection: OverviewProjection,
    selection: OverviewSelection?,
    drag: OverviewDragPresentation?,
    borderStyle: WindowBorderStyle,
    windowCornerRadius: Double,
    previews: [WindowID: NSImage],
    previewOpacities: [WindowID: Double]
  ) -> Bool {
    let visibleWindowIDs = Set(projection.workspaces.flatMap(\.windows).map(\.windowID))
    let visiblePreviews = previews.filter { visibleWindowIDs.contains($0.key) }
    let visibleOpacities = previewOpacities.filter { visiblePreviews[$0.key] != nil }
    guard self.snapshot != snapshot || self.projection != projection
      || self.selection != selection || self.drag != drag
      || self.borderStyle != borderStyle || self.windowCornerRadius != windowCornerRadius
      || self.previews != visiblePreviews || self.previewOpacities != visibleOpacities
    else { return false }
    presentationUpdateCount += 1
    if self.snapshot != snapshot { titleCache.prune(windowIDs: Set(snapshot.windows.keys)) }
    self.snapshot = snapshot
    self.projection = projection
    self.selection = selection
    self.drag = drag
    self.borderStyle = borderStyle
    self.windowCornerRadius = windowCornerRadius
    self.previews = visiblePreviews
    self.previewOpacities = visibleOpacities
    dropSettledOutgoingPreviews()
    needsDisplay = true
    return true
  }

  func updatePreview(_ image: NSImage, for windowID: WindowID, opacity: Double) {
    if let current = previews[windowID], current !== image, opacity < 1 {
      outgoingPreviews[windowID] = current
    }
    previews[windowID] = image
    previewOpacities[windowID] = opacity
    dropSettledOutgoingPreviews()
    needsDisplay = true
  }

  func updatePreviewOpacities(_ opacities: [WindowID: Double]) {
    let visible = opacities.filter { previews[$0.key] != nil }
    guard visible != previewOpacities else { return }
    previewOpacities = visible
    dropSettledOutgoingPreviews()
    needsDisplay = true
  }

  private func dropSettledOutgoingPreviews() {
    outgoingPreviews = outgoingPreviews.filter { (previewOpacities[$0.key] ?? 1) < 1 }
  }

  override func updateLayer() {
    guard let projection, let snapshot else { return }
    renderCount += 1
    if canvas.superlayer !== layer { layer?.addSublayer(canvas) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    var colors = OverviewLayerColors()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      colors = OverviewLayerColors(
        background: NSColor.windowBackgroundColor.cgColor,
        accent: NSColor.controlAccentColor.cgColor
      )
    }
    setFrame(canvas, bounds)
    var groups: [CALayer] = []
    var overlay: [CALayer] = []
    var liveWorkspaces = Set<WorkspaceID>()
    var liveWindows = Set<WindowID>()
    for workspace in projection.workspaces {
      let layers = workspaceLayers[workspace.workspaceID] ?? OverviewWorkspaceLayers()
      workspaceLayers[workspace.workspaceID] = layers
      liveWorkspaces.insert(workspace.workspaceID)
      groups.append(layers.group)
      overlay += renderWorkspace(workspace, layers: layers, snapshot: snapshot, colors: colors,
        liveWindows: &liveWindows)
    }
    desktopFadeDuration = 0
    for (id, layers) in workspaceLayers where !liveWorkspaces.contains(id) {
      layers.group.removeFromSuperlayer()
      workspaceLayers[id] = nil
    }
    for (id, card) in cardLayers where !liveWindows.contains(id) {
      card.root.removeFromSuperlayer()
      cardLayers[id] = nil
    }
    for (id, border) in borderLayers where !liveWindows.contains(id) {
      border.removeFromSuperlayer()
      borderLayers[id] = nil
    }
    setSublayers(overlayLayer, overlay)
    setFrame(overlayLayer, bounds)
    renderDraggedCard(snapshot: snapshot, colors: colors)
    renderDropTarget(projection: projection, colors: colors)
    setSublayers(canvas, groups + [overlayLayer, dragLayer, dropBand, dropLine])
  }

  /// Lays out one workspace and returns the overlay card's layers, which stack above
  /// every workspace.
  private func renderWorkspace(
    _ workspace: OverviewWorkspaceProjection,
    layers: OverviewWorkspaceLayers,
    snapshot: OverviewSnapshot,
    colors: OverviewLayerColors,
    liveWindows: inout Set<WindowID>
  ) -> [CALayer] {
    let frame = cgRect(workspace.frame)
    let visibleFrame = cgRect(workspace.visibleFrame)
    let scale = contentScale(for: workspace, snapshot: snapshot)
    let borderWidth = borderStyle.width * scale
    setFrame(layers.group, bounds)
    setFrame(layers.desktop, visibleFrame)
    setFrame(layers.dim, CGRect(origin: .zero, size: visibleFrame.size))
    layers.desktop.cornerRadius = windowCornerRadius
    if (layers.desktop.contents as AnyObject?) !== desktopImage {
      if desktopFadeDuration > 0, layers.desktop.contents != nil {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = desktopFadeDuration
        layers.desktop.add(transition, forKey: "desktopImage")
      } else {
        layers.desktop.removeAnimation(forKey: "desktopImage")
      }
      layers.desktop.contents = desktopImage
    }
    layers.desktop.backgroundColor = desktopImage == nil ? colors.background : nil
    setFrame(layers.tiled, frame)
    setFrame(layers.floating, visibleFrame)
    setFrame(layers.tiledBorders, frame.insetBy(dx: -borderWidth, dy: -borderWidth))
    setFrame(layers.floatingBorders, visibleFrame.insetBy(dx: -borderWidth, dy: -borderWidth))

    var tiled: [CALayer] = [], floating: [CALayer] = []
    var tiledBorders: [CALayer] = [], floatingBorders: [CALayer] = []
    var overlay: [CALayer] = []
    for card in workspace.windows {
      guard let window = snapshot.windows[card.windowID] else { continue }
      liveWindows.insert(card.windowID)
      let cardLayer = cardLayers[card.windowID] ?? OverviewCardLayers()
      cardLayers[card.windowID] = cardLayer
      let border = borderLayers[card.windowID] ?? CALayer()
      borderLayers[card.windowID] = border
      let isFloating = card.layer == .floating
      let isOverlay = projection?.overlayWindowID == card.windowID
      let (container, borderContainer) = if isOverlay {
        (overlayLayer, overlayLayer)
      } else if isFloating {
        (layers.floating, layers.floatingBorders)
      } else {
        (layers.tiled, layers.tiledBorders)
      }
      renderCard(card, window: window, layers: cardLayer, origin: container.frame.origin)
      renderBorder(card, scale: scale, layer: border, origin: borderContainer.frame.origin)
      if isOverlay {
        overlay += [cardLayer.root, border]
      } else if drag?.windowID != card.windowID {
        if isFloating {
          floating.append(cardLayer.root)
          floatingBorders.append(border)
        } else {
          tiled.append(cardLayer.root)
          tiledBorders.append(border)
        }
      }
    }
    setSublayers(layers.tiled, tiled)
    setSublayers(layers.floating, floating)
    setSublayers(layers.tiledBorders, tiledBorders)
    setSublayers(layers.floatingBorders, floatingBorders)
    renderOverflowIndicator(layers.leading, count: workspace.hiddenTiledWindowCountBefore,
      leading: true, in: frame)
    renderOverflowIndicator(layers.trailing, count: workspace.hiddenTiledWindowCountAfter,
      leading: false, in: frame)
    return overlay
  }

  private func renderCard(
    _ card: OverviewWindowProjection,
    window: Window,
    layers: OverviewCardLayers,
    origin: CGPoint
  ) {
    let frame = cgRect(card.frame)
    let size = frame.size
    setFrame(layers.root, frame.offsetBy(dx: -origin.x, dy: -origin.y))
    layers.root.isHidden = suppressedSurfaceWindowIDs.contains(card.windowID)
    layers.root.cornerRadius = windowCornerRadius
    layers.root.backgroundColor = card.isNativeFullscreen
      ? OverviewCardLayers.fullscreenBackground : OverviewCardLayers.background
    let bounds = CGRect(origin: .zero, size: size)
    let preview = previews[card.windowID]
    if surfaceWindowIDs.contains(card.windowID), let preview {
      show(layers.preview, preview, in: bounds)
      layers.preview.opacity = 1
      for layer in [layers.outgoing, layers.scrim, layers.icon, layers.title, layers.fullScreen] {
        layer.isHidden = true
      }
      return
    }
    let iconSize = overviewWindowTitleIconSize(cardHeight: size.height)
    let titleBandHeight = overviewWindowTitleBandHeight(iconSize: iconSize)
    if let preview {
      let opacity = previewOpacities[card.windowID] ?? 1
      let outgoing = outgoingPreviews[card.windowID]
      if let outgoing {
        show(layers.outgoing, outgoing, in: bounds,
          contentsRect: aspectFillContentsRect(for: outgoing, in: size))
      } else {
        layers.outgoing.isHidden = true
      }
      show(layers.preview, preview, in: bounds,
        contentsRect: aspectFillContentsRect(for: preview, in: size))
      layers.preview.opacity = Float(opacity)
      let fadeHeight = overviewPreviewBlurFadeHeight(
        titleBandHeight: titleBandHeight, imageScale: 1, imageHeight: size.height)
      show(layers.scrim, titleScrimImage,
        in: CGRect(x: 0, y: 0, width: size.width, height: fadeHeight))
      // Cross-fades keep the scrim steady; only a first reveal fades it in.
      layers.scrim.opacity = Float(outgoing == nil ? opacity : 1)
    } else {
      for layer in [layers.preview, layers.outgoing, layers.scrim] { layer.isHidden = true }
    }
    let title = window.title.isEmpty ? window.appID : window.title
    let fontSize = min(13, max(size.height * 0.09, 10))
    let label = titleCache.label(for: card.windowID, text: title, fontSize: fontSize,
      maximumWidth: max(size.width - iconSize - 28, 1), scale: windowBackingScale)
    let titleLayout = overviewWindowTitleLayout(
      cardFrame: bounds,
      iconSize: iconSize,
      titleSize: label?.intrinsicSize ?? .zero,
      blurHeight: titleBandHeight
    )
    show(layers.icon, icon(for: window), in: titleLayout.iconFrame)
    if let label {
      show(layers.title, label.image, in: titleLayout.titleFrame)
    } else {
      layers.title.isHidden = true
    }
    if card.isNativeFullscreen, let fullScreen = labelImage("Full Screen", size: nil, attributes: [
      .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(0.58),
    ]) {
      show(layers.fullScreen, fullScreen, in: CGRect(
        origin: CGPoint(x: 10, y: size.height - 26), size: fullScreen.size))
    } else {
      layers.fullScreen.isHidden = true
    }
  }

  private func renderBorder(
    _ card: OverviewWindowProjection,
    scale: Double,
    layer: CALayer,
    origin: CGPoint
  ) {
    let selected = selection?.windowID == card.windowID && selection?.location.monitorID == monitorID
    guard let border = overviewWindowBorderAppearance(
      isSelected: selected,
      style: borderStyle,
      scale: scale
    ) else {
      layer.isHidden = true
      return
    }
    let geometry = overviewWindowBorderGeometry(
      cardFrame: card.frame,
      cardRadius: windowCornerRadius,
      width: border.width,
      placement: borderStyle.placement
    )
    // A layer border lies inside its bounds; widen it by half so it covers the
    // same band as a stroke centred on the border path.
    let half = border.width / 2
    setFrame(layer, cgRect(geometry.frame).insetBy(dx: -half, dy: -half)
      .offsetBy(dx: -origin.x, dy: -origin.y))
    layer.cornerRadius = geometry.radius + half
    layer.borderWidth = border.width
    layer.borderColor = overviewBorderColor(border.color)
    layer.isHidden = false
  }

  private func renderOverflowIndicator(
    _ layer: CALayer,
    count: Int,
    leading: Bool,
    in frame: CGRect
  ) {
    let indicatorFrame = horizontalOverflowIndicatorFrame(leading: leading, in: frame)
    guard count > 0, let image = labelImage(
      leading ? "\u{2190} \(count)" : "\(count) \u{2192}",
      size: indicatorFrame.insetBy(dx: 8, dy: 6).size,
      attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .paragraphStyle: centeredParagraphStyle,
      ]
    ) else {
      layer.isHidden = true
      return
    }
    setFrame(layer, indicatorFrame)
    show(layer.sublayers![0], image, in: CGRect(x: 8, y: 6,
      width: indicatorFrame.width - 16, height: indicatorFrame.height - 12))
    layer.isHidden = false
  }

  private func renderDraggedCard(snapshot: OverviewSnapshot, colors: OverviewLayerColors) {
    guard let drag, let point = drag.localPoint,
      let window = snapshot.windows[drag.windowID]
    else {
      dragLayer.isHidden = true
      return
    }
    let frame = CGRect(
      x: point.x - drag.cardSize.width / 2,
      y: point.y - drag.cardSize.height / 2,
      width: drag.cardSize.width,
      height: drag.cardSize.height
    )
    setFrame(dragLayer, frame)
    dragLayer.cornerRadius = windowCornerRadius
    setFrame(dragBorder, CGRect(origin: .zero, size: frame.size).insetBy(dx: -1.5, dy: -1.5))
    dragBorder.cornerRadius = windowCornerRadius + 1.5
    dragBorder.borderColor = colors.accent
    setFrame(dragTitle, CGRect(origin: .zero, size: frame.size).insetBy(dx: 12, dy: 10))
    let title = window.title.isEmpty ? window.appID : window.title
    if (dragTitle.string as? NSAttributedString)?.string != title {
      dragTitle.string = NSAttributedString(string: title, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white,
      ])
    }
    dragTitle.contentsScale = windowBackingScale
    dragLayer.isHidden = false
  }

  private func renderDropTarget(projection: OverviewProjection, colors: OverviewLayerColors) {
    dropBand.isHidden = true
    dropLine.isHidden = true
    dropBand.backgroundColor = colors.accent.copy(alpha: 0.18)
    dropLine.backgroundColor = colors.accent
    switch drag?.target {
    case .newColumn(_, let workspaceID, let columnIndex):
      guard let workspace = projection.workspaces.first(where: {
        $0.workspaceID == workspaceID
      }) else { return }
      let columns = workspace.windows.compactMap { window -> (Int, Rect)? in
        guard case .tiled(let index, _) = window.layer else { return nil }
        return (index, window.frame)
      }
      let x = columns.filter { $0.0 == columnIndex }.map(\.1.x).min()
        ?? columns.map { $0.1.x + $0.1.width }.max()
        ?? workspace.frame.x + 8
      setFrame(dropBand, CGRect(x: x - 10, y: workspace.frame.y + 8,
        width: 20, height: workspace.frame.height - 16))
      setFrame(dropLine, CGRect(x: x - 1.5, y: workspace.frame.y + 12,
        width: 3, height: workspace.frame.height - 24))
      dropBand.isHidden = false
      dropLine.isHidden = false
    case .stack(_, let workspaceID, let columnIndex, let windowIndex):
      let cards = projection.workspaces.first(where: {
        $0.workspaceID == workspaceID
      })?.windows.filter {
        if case .tiled(let index, _) = $0.layer { return index == columnIndex }
        return false
      }.sorted { $0.frame.y < $1.frame.y } ?? []
      guard let first = cards.first, let last = cards.last else { return }
      let y = windowIndex < cards.count
        ? cards[windowIndex].frame.y
        : last.frame.y + last.frame.height
      setFrame(dropLine, CGRect(x: first.frame.x + 8, y: y - 2,
        width: first.frame.width - 16, height: 4))
      dropLine.isHidden = false
    case .floating, nil:
      break
    }
  }

  override func accessibilityChildren() -> [Any]? {
    guard let projection, let snapshot, let window else { return [] }
    return projection.workspaces.flatMap { workspace -> [NSAccessibilityElement] in
      let workspaceElement = NSAccessibilityElement()
      workspaceElement.setAccessibilityParent(self)
      workspaceElement.setAccessibilityRole(.group)
      workspaceElement.setAccessibilityEnabled(true)
      workspaceElement.setAccessibilityLabel("Workspace \(workspace.label)")
      workspaceElement.setAccessibilityFrame(
        window.convertToScreen(convert(cgRect(workspace.frame), to: nil))
      )
      let windowElements = workspace.windows.compactMap { card -> NSAccessibilityElement? in
        guard let managedWindow = snapshot.windows[card.windowID] else { return nil }
        let visibleFrame = cgRect(card.frame).intersection(cgRect(workspace.frame))
        guard !visibleFrame.isEmpty else { return nil }
        let element = OverviewAccessibilityElement { [weak self] in
          guard let self else { return }
          self.delegate?.overviewView(
            self,
            clickedAt: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
          )
        }
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.button)
        element.setAccessibilityEnabled(true)
        element.setAccessibilityLabel(
          managedWindow.title.isEmpty ? managedWindow.appID : managedWindow.title
        )
        element.setAccessibilityHelp("Workspace \(workspace.label)")
        element.setAccessibilitySelected(selection?.windowID == card.windowID)
        element.setAccessibilityFrame(
          window.convertToScreen(convert(visibleFrame, to: nil))
        )
        return element
      }
      return [workspaceElement] + windowElements
    }
  }

  private func show(
    _ layer: CALayer,
    _ image: NSImage?,
    in frame: CGRect,
    contentsRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
  ) {
    if (layer.contents as AnyObject?) !== image { layer.contents = image }
    setFrame(layer, frame)
    if layer.contentsRect != contentsRect { layer.contentsRect = contentsRect }
    layer.isHidden = image == nil
  }

  // Unchanged geometry is not reassigned, so an idle card adds nothing to the commit.
  private func setFrame(_ layer: CALayer, _ frame: CGRect) {
    if layer.frame != frame { layer.frame = frame }
  }

  private func setSublayers(_ layer: CALayer, _ sublayers: [CALayer]) {
    let current = layer.sublayers ?? []
    guard current.count != sublayers.count
      || zip(current, sublayers).contains(where: { $0 !== $1 })
    else { return }
    layer.sublayers = sublayers
  }

  // The unit rectangle of the image that fills `size`, anchored to the leading edge
  // like the window's own content.
  private func aspectFillContentsRect(for image: NSImage, in size: CGSize) -> CGRect {
    guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0
    else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let imageRatio = image.size.width / image.size.height
    let frameRatio = size.width / size.height
    if imageRatio > frameRatio {
      return CGRect(x: 0, y: 0, width: frameRatio / imageRatio, height: 1)
    }
    let height = imageRatio / frameRatio
    return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
  }

  private func contentScale(
    for workspace: OverviewWorkspaceProjection,
    snapshot: OverviewSnapshot
  ) -> Double {
    guard let monitorFrame = snapshot.monitorFrames[monitorID], monitorFrame.height > 0 else {
      return 1
    }
    return workspace.frame.height / monitorFrame.height
  }

  private var centeredParagraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return style
  }

  // Short fixed labels are rasterized once per text and reused by every card.
  private func labelImage(
    _ text: String,
    size: CGSize?,
    attributes: [NSAttributedString.Key: Any]
  ) -> NSImage? {
    let key = "\(text)|\(size.map { "\($0.width)x\($0.height)" } ?? "")@\(windowBackingScale)"
    if let cached = labelImages[key] { return cached }
    let string = text as NSString
    let imageSize = size ?? string.size(withAttributes: attributes)
    let image = overviewLabelBitmap(size: imageSize, scale: windowBackingScale) {
      string.draw(in: CGRect(origin: .zero, size: imageSize), withAttributes: attributes)
    }
    labelImages[key] = image
    return image
  }

  private func icon(for window: Window) -> NSImage {
    if let cached = iconCache[window.appID] { return cached }
    let icon = NSImage(systemSymbolName: "app", accessibilityDescription: window.appID)
      ?? NSImage(size: NSSize(width: 24, height: 24))
    iconCache[window.appID] = rasterizedIcon(icon)
    if let processID = window.processID {
      Task { @MainActor [weak self] in
        let loaded = await Task.detached(priority: .utility) {
          NSRunningApplication(processIdentifier: processID)?.icon
        }.value
        guard let self, let loaded else { return }
        self.iconCache[window.appID] = self.rasterizedIcon(loaded)
        self.needsDisplay = true
      }
    }
    return iconCache[window.appID] ?? icon
  }

  private var windowBackingScale: CGFloat { window?.backingScaleFactor ?? 2 }

  private func rasterizedIcon(_ image: NSImage) -> NSImage {
    let size = CGSize(width: 24, height: 24)
    return overviewLabelBitmap(size: size, scale: 2) {
      image.draw(in: CGRect(origin: .zero, size: size), from: .zero,
        operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
    } ?? image
  }

  private func overviewBorderColor(_ value: UInt32) -> CGColor {
    CGColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255,
      green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255,
      alpha: CGFloat(windowBorderAlpha(of: value)) / 255
    )
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    mouseDownPoint = point
    mouseDownOverflow = horizontalOverflowAction(at: point)
    if mouseDownOverflow == nil {
      mouseDownWindowID = projection?.hitTest(
        OverviewPoint(x: point.x, y: point.y)
      ).flatMap { hit in
        if case .window(let windowID, _, _) = hit { return windowID }
        return nil
      }
    } else {
      mouseDownWindowID = nil
    }
    leftDragStarted = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = mouseDownPoint, let windowID = mouseDownWindowID else { return }
    let point = convert(event.locationInWindow, from: nil)
    let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    if !leftDragStarted, hypot(point.x - start.x, point.y - start.y) >= 5 {
      leftDragStarted = true
      delegate?.overviewView(self, beganDragging: windowID, at: screenPoint)
    }
    if leftDragStarted {
      delegate?.overviewView(self, draggedTo: screenPoint)
    }
  }

  override func mouseUp(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if leftDragStarted {
      let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
      delegate?.overviewView(self, endedDraggingAt: screenPoint)
    } else if let pressed = mouseDownOverflow,
      let released = horizontalOverflowAction(at: point),
      pressed.workspaceID == released.workspaceID,
      pressed.direction == released.direction
    {
      delegate?.overviewView(
        self,
        pageWorkspace: released.workspaceID,
        direction: released.direction
      )
    } else {
      delegate?.overviewView(self, clickedAt: point)
    }
    mouseDownPoint = nil
    mouseDownWindowID = nil
    mouseDownOverflow = nil
    leftDragStarted = false
  }

  override func rightMouseDown(with event: NSEvent) {
    rightDragPoint = convert(event.locationInWindow, from: nil)
  }

  override func rightMouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let previous = rightDragPoint else { return }
    delegate?.overviewView(self, rightDraggedBy: point.x - previous.x, at: point)
    rightDragPoint = point
  }

  override func rightMouseUp(with event: NSEvent) {
    rightDragPoint = nil
  }

  override func scrollWheel(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    delegate?.overviewView(
      self,
      scrolled: NSPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY),
      hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
      at: point
    )
  }

  private func cgRect(_ rect: Rect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }

  private func horizontalOverflowAction(
    at point: NSPoint
  ) -> (workspaceID: WorkspaceID, direction: Int)? {
    guard let projection else { return nil }
    for workspace in projection.workspaces.reversed() {
      let frame = cgRect(workspace.frame)
      if workspace.hiddenTiledWindowCountBefore > 0,
        horizontalOverflowIndicatorFrame(leading: true, in: frame).contains(point)
      {
        return (workspace.workspaceID, -1)
      }
      if workspace.hiddenTiledWindowCountAfter > 0,
        horizontalOverflowIndicatorFrame(leading: false, in: frame).contains(point)
      {
        return (workspace.workspaceID, 1)
      }
    }
    return nil
  }

  private func horizontalOverflowIndicatorFrame(
    leading: Bool,
    in frame: NSRect
  ) -> NSRect {
    let size = NSSize(width: 46, height: 30)
    return NSRect(
      x: leading ? frame.minX + 12 : frame.maxX - size.width - 12,
      y: frame.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }
}

private struct OverviewLayerColors {
  var background = CGColor(gray: 0.2, alpha: 1)
  var accent = CGColor(gray: 1, alpha: 1)
}

// One workspace in draw order: wallpaper, clipped cards, borders, then overflow badges.
@MainActor
private final class OverviewWorkspaceLayers {
  let group = CALayer()
  let desktop = CALayer()
  let dim = CALayer()
  let tiled = CALayer()
  let floating = CALayer()
  let tiledBorders = CALayer()
  let floatingBorders = CALayer()
  let leading = CALayer()
  let trailing = CALayer()

  init() {
    desktop.masksToBounds = true
    desktop.contentsGravity = .resizeAspectFill
    dim.backgroundColor = CGColor(gray: 0, alpha: 0.12)
    desktop.addSublayer(dim)
    for clip in [tiled, floating, tiledBorders, floatingBorders] { clip.masksToBounds = true }
    for indicator in [leading, trailing] {
      indicator.cornerRadius = 15
      indicator.backgroundColor = CGColor(gray: 0, alpha: 0.72)
      indicator.addSublayer(CALayer())
    }
    group.sublayers = [desktop, tiled, floating, tiledBorders, floatingBorders, leading, trailing]
  }
}

@MainActor
private final class OverviewCardLayers {
  static let background = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
  static let fullscreenBackground = NSColor(calibratedWhite: 0.19, alpha: 1).cgColor
  let root = CALayer()
  let outgoing = CALayer()
  let preview = CALayer()
  let scrim = CALayer()
  let icon = CALayer()
  let title = CALayer()
  let fullScreen = CALayer()

  init() {
    root.masksToBounds = true
    for layer in [outgoing, preview, scrim] { layer.contentsGravity = .resize }
    root.sublayers = [outgoing, preview, scrim, icon, title, fullScreen]
  }
}

func overviewWindowTitleIconSize(cardHeight: CGFloat) -> CGFloat {
  min(24, max(cardHeight * 0.16, 14))
}

func overviewWindowTitleBandHeight(iconSize: CGFloat) -> CGFloat {
  iconSize + 20
}

func overviewTitleScrimAlpha(progress: CGFloat, opacity: CGFloat) -> CGFloat {
  let remaining = 1 - min(max(progress, 0), 1)
  return 0.48 * opacity * remaining * remaining
}

func overviewWindowTitleLayout(
  cardFrame: CGRect,
  iconSize: CGFloat,
  titleSize: CGSize,
  blurHeight: CGFloat
) -> (iconFrame: CGRect, titleFrame: CGRect) {
  let spacing = 8.0
  let titleWidth = min(titleSize.width, max(cardFrame.width - iconSize - spacing - 20, 1))
  let iconX = cardFrame.minX + 10
  let centerY = cardFrame.minY + blurHeight / 2
  return (
    CGRect(
      x: iconX,
      y: centerY - iconSize / 2,
      width: iconSize,
      height: iconSize
    ),
    CGRect(
      x: iconX + iconSize + spacing,
      y: centerY - titleSize.height / 2,
      width: titleWidth,
      height: titleSize.height
    )
  )
}

@MainActor
private final class OverviewAccessibilityElement: NSAccessibilityElement {
  private nonisolated let press: @MainActor @Sendable () -> Void

  init(press: @escaping @MainActor @Sendable () -> Void) {
    self.press = press
    super.init()
  }

  nonisolated override func accessibilityPerformPress() -> Bool {
    let press = press
    Task { @MainActor in press() }
    return true
  }
}
