import AppKit
import DefiConfig
import DefiCore
import DefiModel

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
  private var desktopImage: NSImage?
  private var previews: [WindowID: NSImage] = [:]
  private var previewOpacities: [WindowID: Double] = [:]
  private var mouseDownPoint: NSPoint?
  private var mouseDownWindowID: WindowID?
  private var mouseDownOverflow: (workspaceID: WorkspaceID, direction: Int)?
  private var leftDragStarted = false
  private var rightDragPoint: NSPoint?
  private var iconCache: [String: NSImage] = [:]

  override var isFlipped: Bool { true }

  init(monitorID: MonitorID, delegate: OverviewViewDelegate) {
    self.monitorID = monitorID
    self.delegate = delegate
    super.init(frame: .zero)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Defi Overview")
  }

  func discardPreviewImages() {
    previews.removeAll(keepingCapacity: false)
  }

  func setDesktopImage(_ image: NSImage) {
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
    self.snapshot = snapshot
    self.projection = projection
    self.selection = selection
    self.drag = drag
    self.borderStyle = borderStyle
    self.windowCornerRadius = windowCornerRadius
    self.previews = visiblePreviews
    self.previewOpacities = visibleOpacities
    needsDisplay = true
    return true
  }

  func updatePreviewOpacities(_ opacities: [WindowID: Double]) {
    let visible = opacities.filter { previews[$0.key] != nil }
    guard visible != previewOpacities else { return }
    previewOpacities = visible
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let projection, let snapshot else { return }
    for workspace in projection.workspaces {
      drawWorkspace(workspace, snapshot: snapshot)
    }
    if let overlayWindowID = projection.overlayWindowID,
      let workspace = projection.workspaces.first(where: {
        $0.windows.contains { $0.windowID == overlayWindowID }
      }),
      let overlay = workspace.windows.first(where: { $0.windowID == overlayWindowID })
    {
      drawWindow(overlay, snapshot: snapshot)
      drawWindowBorder(overlay, scale: contentScale(for: workspace, snapshot: snapshot))
    }
    drawDraggedCard(snapshot: snapshot)
    drawDropTarget()
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
        window.convertToScreen(convert(nsRect(workspace.frame), to: nil))
      )
      let windowElements = workspace.windows.compactMap { card -> NSAccessibilityElement? in
        guard let managedWindow = snapshot.windows[card.windowID] else { return nil }
        let visibleFrame = nsRect(card.frame).intersection(nsRect(workspace.frame))
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

  private func drawWorkspace(
    _ workspace: OverviewWorkspaceProjection,
    snapshot: OverviewSnapshot
  ) {
    let frame = nsRect(workspace.frame)
    let scale = contentScale(for: workspace, snapshot: snapshot)
    drawVisibleDesktop(for: workspace)
    NSGraphicsContext.saveGraphicsState()
    frame.clip()
    for window in workspace.windows
    where window.layer != .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindow(window, snapshot: snapshot)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    nsRect(workspace.visibleFrame).clip()
    for window in workspace.windows
    where window.layer == .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindow(window, snapshot: snapshot)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    let borderWidth = borderStyle.width * scale
    frame.insetBy(dx: -borderWidth, dy: -borderWidth).clip()
    for window in workspace.windows
    where window.layer != .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindowBorder(window, scale: scale)
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    nsRect(workspace.visibleFrame).insetBy(
      dx: -borderWidth,
      dy: -borderWidth
    ).clip()
    for window in workspace.windows
    where window.layer == .floating
      && drag?.windowID != window.windowID
      && projection?.overlayWindowID != window.windowID
    {
      drawWindowBorder(window, scale: scale)
    }
    NSGraphicsContext.restoreGraphicsState()
    drawHorizontalOverflowIndicators(for: workspace)
  }

  private func drawVisibleDesktop(for workspace: OverviewWorkspaceProjection) {
    let frame = nsRect(workspace.visibleFrame)
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    if let desktopImage {
      desktopImage.draw(
        in: frame,
        from: aspectFillSourceRect(for: desktopImage, in: frame),
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
    } else {
      NSColor.windowBackgroundColor.setFill()
      path.fill()
    }
    NSColor.black.withAlphaComponent(0.12).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func aspectFillSourceRect(
    for image: NSImage,
    in frame: NSRect,
    horizontalAlignment: CGFloat = 0.5
  ) -> NSRect {
    guard image.size.width > 0, image.size.height > 0, frame.width > 0, frame.height > 0
    else { return .zero }
    let imageRatio = image.size.width / image.size.height
    let frameRatio = frame.width / frame.height
    if imageRatio > frameRatio {
      let width = image.size.height * frameRatio
      return NSRect(
        x: (image.size.width - width) * horizontalAlignment,
        y: 0,
        width: width,
        height: image.size.height
      )
    }
    let height = image.size.width / frameRatio
    return NSRect(
      x: 0,
      y: (image.size.height - height) / 2,
      width: image.size.width,
      height: height
    )
  }

  private func drawWindow(
    _ card: OverviewWindowProjection,
    snapshot: OverviewSnapshot
  ) {
    guard let window = snapshot.windows[card.windowID] else { return }
    let frame = nsRect(card.frame)
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSColor(calibratedWhite: card.isNativeFullscreen ? 0.19 : 0.15, alpha: 1).setFill()
    path.fill()
    let iconSize = overviewWindowTitleIconSize(cardHeight: frame.height)
    let titleBandHeight = overviewWindowTitleBandHeight(iconSize: iconSize)
    let titleFadeHeight = overviewPreviewBlurFadeHeight(
      titleBandHeight: titleBandHeight,
      imageScale: 1,
      imageHeight: frame.height
    )
    if let preview = previews[card.windowID] {
      let opacity = previewOpacities[card.windowID] ?? 1
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      preview.draw(
        in: frame,
        from: aspectFillSourceRect(for: preview, in: frame, horizontalAlignment: 0),
        operation: .sourceOver,
        fraction: opacity,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
      )
      NSGradient(
        colorsAndLocations:
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0, opacity: CGFloat(opacity))
          ), 0),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.25, opacity: CGFloat(opacity))
          ), 0.25),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.5, opacity: CGFloat(opacity))
          ), 0.5),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.75, opacity: CGFloat(opacity))
          ), 0.75),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.9, opacity: CGFloat(opacity))
          ), 0.9),
          (NSColor.black.withAlphaComponent(
            overviewTitleScrimAlpha(progress: 0.97, opacity: CGFloat(opacity))
          ), 0.97),
          (NSColor.clear, 1)
      )?.draw(
        from: NSPoint(x: frame.midX, y: frame.minY),
        to: NSPoint(x: frame.midX, y: frame.minY + titleFadeHeight),
        options: []
      )
      NSGraphicsContext.restoreGraphicsState()
    }
    let title = (window.title.isEmpty ? window.appID : window.title) as NSString
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: min(13, max(frame.height * 0.09, 10)), weight: .medium),
      .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]
    let titleLayout = overviewWindowTitleLayout(
      cardFrame: frame,
      iconSize: iconSize,
      titleSize: title.size(withAttributes: titleAttributes),
      blurHeight: titleBandHeight
    )
    let icon = icon(for: window)
    icon.draw(in: titleLayout.iconFrame)
    title.draw(in: titleLayout.titleFrame, withAttributes: titleAttributes)
    if card.isNativeFullscreen {
      let label = "Full Screen" as NSString
      label.draw(
        at: NSPoint(x: frame.minX + 10, y: frame.maxY - 26),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
          .foregroundColor: NSColor.white.withAlphaComponent(0.58),
        ]
      )
    }
  }

  private func drawWindowBorder(_ card: OverviewWindowProjection, scale: Double) {
    let selected = selection == .window(
      windowID: card.windowID,
      monitorID: monitorID,
      workspaceID: selection?.location?.workspaceID ?? WorkspaceID(rawValue: "")
    )
    if let border = overviewWindowBorderAppearance(
      isSelected: selected,
      style: borderStyle,
      scale: scale
    ) {
      overviewBorderColor(border.color).setStroke()
      let geometry = overviewWindowBorderGeometry(
        cardFrame: card.frame,
        cardRadius: windowCornerRadius,
        width: border.width,
        placement: borderStyle.placement
      )
      let borderPath = NSBezierPath(
        roundedRect: nsRect(geometry.frame),
        xRadius: geometry.radius,
        yRadius: geometry.radius
      )
      borderPath.lineWidth = border.width
      borderPath.stroke()
    }
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

  private func drawHorizontalOverflowIndicators(
    for workspace: OverviewWorkspaceProjection
  ) {
    if workspace.hiddenTiledWindowCountBefore > 0 {
      drawHorizontalOverflowIndicator(
        "\u{2190} \(workspace.hiddenTiledWindowCountBefore)",
        leading: true,
        in: nsRect(workspace.frame)
      )
    }
    if workspace.hiddenTiledWindowCountAfter > 0 {
      drawHorizontalOverflowIndicator(
        "\(workspace.hiddenTiledWindowCountAfter) \u{2192}",
        leading: false,
        in: nsRect(workspace.frame)
      )
    }
  }

  private func drawHorizontalOverflowIndicator(
    _ label: String,
    leading: Bool,
    in frame: NSRect
  ) {
    let indicatorFrame = horizontalOverflowIndicatorFrame(leading: leading, in: frame)
    let path = NSBezierPath(roundedRect: indicatorFrame, xRadius: 15, yRadius: 15)
    NSColor.black.withAlphaComponent(0.72).setFill()
    path.fill()
    (label as NSString).draw(
      in: indicatorFrame.insetBy(dx: 8, dy: 6),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        .paragraphStyle: centeredParagraphStyle,
      ]
    )
  }

  private var centeredParagraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    return style
  }

  private func icon(for window: Window) -> NSImage {
    if let cached = iconCache[window.appID] { return cached }
    let icon = window.processID.flatMap {
      NSRunningApplication(processIdentifier: pid_t($0))?.icon
    } ?? NSImage(systemSymbolName: "app", accessibilityDescription: window.appID)
      ?? NSImage(size: NSSize(width: 24, height: 24))
    iconCache[window.appID] = icon
    return icon
  }

  private func overviewBorderColor(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xff) / 255,
      green: CGFloat((value >> 8) & 0xff) / 255,
      blue: CGFloat(value & 0xff) / 255,
      alpha: CGFloat(windowBorderAlpha(of: value)) / 255
    )
  }

  private func drawDropTarget() {
    guard let target = drag?.target, let projection else { return }
    NSColor.controlAccentColor.setStroke()
    switch target {
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
      let band = NSBezierPath(
        roundedRect: NSRect(
          x: x - 10,
          y: workspace.frame.y + 8,
          width: 20,
          height: workspace.frame.height - 16
        ),
        xRadius: 10,
        yRadius: 10
      )
      NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
      band.fill()
      NSColor.controlAccentColor.setStroke()
      let path = NSBezierPath()
      path.move(to: NSPoint(x: x, y: workspace.frame.y + 12))
      path.line(to: NSPoint(x: x, y: workspace.frame.y + workspace.frame.height - 12))
      path.lineWidth = 3
      path.stroke()
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
      let path = NSBezierPath()
      path.move(to: NSPoint(x: first.frame.x + 8, y: y))
      path.line(to: NSPoint(x: first.frame.x + first.frame.width - 8, y: y))
      path.lineWidth = 4
      path.stroke()
    case .floating:
      break
    }
  }

  private func drawDraggedCard(snapshot: OverviewSnapshot) {
    guard let drag, let point = drag.localPoint,
      let window = snapshot.windows[drag.windowID]
    else { return }
    let frame = NSRect(
      x: point.x - drag.cardSize.width / 2,
      y: point.y - drag.cardSize.height / 2,
      width: drag.cardSize.width,
      height: drag.cardSize.height
    )
    let path = NSBezierPath(
      roundedRect: frame,
      xRadius: windowCornerRadius,
      yRadius: windowCornerRadius
    )
    NSColor(calibratedWhite: 0.18, alpha: 0.94).setFill()
    path.fill()
    NSColor.controlAccentColor.setStroke()
    path.lineWidth = 3
    path.stroke()
    ((window.title.isEmpty ? window.appID : window.title) as NSString).draw(
      in: frame.insetBy(dx: 12, dy: 10),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.white,
      ]
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

  private func nsRect(_ rect: Rect) -> NSRect {
    NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
  }

  private func horizontalOverflowAction(
    at point: NSPoint
  ) -> (workspaceID: WorkspaceID, direction: Int)? {
    guard let projection else { return nil }
    for workspace in projection.workspaces.reversed() {
      let frame = nsRect(workspace.frame)
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
