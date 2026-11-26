import AppKit
import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import SwiftUI

enum SpacingZone: Hashable {
  case edge(ScreenEdge)
  case between
  /// The band kept free at the top or bottom of the screen, such as for a bar.
  case reserved(top: Bool)
}

/// A screen laid out by the real layout engine at actual point size. Each spacing value is a
/// dimension callout outside the screen, joined to its space by a leader line. Focusing or
/// hovering a value highlights every space it controls.
@MainActor
struct SpacingEditor: View {
  let model: DefiSettingsModel
  @State private var hovered: SpacingZone?
  @SwiftUI.FocusState private var focused: SpacingZone?

  fileprivate static let screenSize = CGSize(width: 400, height: 220)
  fileprivate static let margin = CGSize(width: 84, height: 44)
  /// Distance from the screen outline to a callout's center line.
  private nonisolated static let reach = 26.0
  private nonisolated static let fieldWidth = 40.0

  var body: some View {
    let geometry = SpacingGeometry(config: model.config, size: Self.screenSize)
    let callouts = geometry.anchors.map { Callout(anchor: $0, screen: Self.screenSize) }
    let vector = SpacingDrawing.vector(model.config)
    ZStack(alignment: .topLeading) {
      SpacingDrawing(config: model.config, vector: vector, active: activeZones)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      ForEach(callouts, id: \.zone) { callout in
        calloutControls(callout)
      }
    }
    .frame(
      width: Self.screenSize.width + 2 * Self.margin.width,
      height: Self.screenSize.height + 2 * Self.margin.height
    )
    .animation(.smooth(duration: 0.3), value: vector)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)
    .background(SettingsStageBackground())
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private func calloutControls(_ callout: Callout) -> some View {
    let origin = CGPoint(x: Self.margin.width, y: Self.margin.height)
    let field = CGPoint(x: origin.x + callout.field.x, y: origin.y + callout.field.y)
    switch callout.zone {
    case .reserved(let top):
      self.field(callout.zone).position(field)
      Text(top ? "Space for a top bar" : "Space for a bottom bar").font(.caption).foregroundStyle(.secondary)
        .frame(width: 130, alignment: .leading)
        .position(x: field.x + Self.fieldWidth / 2 + 8 + 65, y: field.y)
    case .between:
      self.field(.between).position(field)
      Text("Gap").font(.caption).foregroundStyle(.secondary)
        .frame(width: 90, alignment: .leading)
        .position(x: field.x + Self.fieldWidth / 2 + 8 + 45, y: field.y)
    case .edge(let edge) where edge == .left || edge == .right:
      VStack(spacing: 4) {
        Text(edge.name).font(.caption).foregroundStyle(.secondary)
        self.field(.edge(edge))
        linkButton(linkChoice(\.linksHorizontalEdges), edges: [.left, .right], help: "Link left and right edges")
      }
      .fixedSize()
      .position(field)
    case .edge(let edge):
      self.field(.edge(edge)).position(field)
      HStack(spacing: 6) {
        Text(edge.name).font(.caption).foregroundStyle(.secondary)
        linkButton(linkChoice(\.linksVerticalEdges), edges: [.top, .bottom], help: "Link top and bottom edges")
      }
      .frame(width: 90, alignment: .leading)
      .position(x: field.x + Self.fieldWidth / 2 + 16 + 45, y: field.y)
    }
  }

  private func linkChoice(_ keyPath: ReferenceWritableKeyPath<DefiSettingsModel, Bool?>) -> Binding<Bool?> {
    Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0 })
  }

  private func linkButton(_ choice: Binding<Bool?>, edges: [ScreenEdge], help: String) -> some View {
    let binding = linkBinding(choice, edges: edges)
    return Button { binding.wrappedValue.toggle() } label: {
      Image(systemName: "link")
        .foregroundStyle(binding.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.5))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityValue(binding.wrappedValue ? "Linked" : "Not linked")
  }

  /// Where a value's leader runs and where its field sits, relative to the screen origin.
  fileprivate struct Callout {
    let zone: SpacingZone
    let leader: [CGPoint]
    let field: CGPoint

    init(anchor: SpacingGeometry.Anchor, screen: CGSize) {
      zone = anchor.zone
      let point = anchor.point
      let reach = SpacingEditor.reach
      let elbow = SpacingEditor.fieldWidth / 2 + 8
      switch anchor.zone {
      case .edge(.top):
        leader = [point, CGPoint(x: point.x, y: -reach), CGPoint(x: point.x - 8, y: -reach)]
        field = CGPoint(x: point.x - elbow, y: -reach)
      case .edge(.bottom):
        leader = [point, CGPoint(x: point.x, y: screen.height + reach), CGPoint(x: point.x - 8, y: screen.height + reach)]
        field = CGPoint(x: point.x - elbow, y: screen.height + reach)
      case .edge(.left):
        field = CGPoint(x: -reach - elbow, y: point.y)
        leader = [point, CGPoint(x: field.x + SpacingEditor.fieldWidth / 2, y: point.y)]
      case .edge(.right):
        field = CGPoint(x: screen.width + reach + elbow, y: point.y)
        leader = [point, CGPoint(x: field.x - SpacingEditor.fieldWidth / 2, y: point.y)]
      case .between:
        let y = screen.height + reach
        leader = [point, CGPoint(x: point.x, y: y), CGPoint(x: point.x + 20, y: y)]
        field = CGPoint(x: point.x + 20 + SpacingEditor.fieldWidth / 2, y: y)
      case .reserved(let top):
        let y = top ? -reach : screen.height + reach
        leader = [point, CGPoint(x: point.x, y: y), CGPoint(x: point.x + 8, y: y)]
        field = CGPoint(x: point.x + elbow, y: y)
      }
    }
  }

  private var activeZones: Set<SpacingZone> {
    switch focused ?? hovered {
    case nil: []
    case .between: [.between]
    case .reserved(let top): [.reserved(top: top)]
    case .edge(let edge): Set(linkedEdges(edge).map(SpacingZone.edge))
    }
  }

  private func field(_ zone: SpacingZone) -> some View {
    let layout = model.config.layout
    let value: Double
    let label: String
    switch zone {
    case .between:
      value = layout.gaps
      label = "Gap between windows"
    case .reserved(let top):
      value = top ? layout.reservedTop : layout.reservedBottom
      label = top ? "Space kept free below the menu bar, for a status bar such as SketchyBar"
        : "Space kept free at the bottom of the screen, for a bar or dock"
    case .edge(let edge):
      value = edge.value(in: layout)
      label = edge.title
    }
    return TextField(
      label,
      value: Binding(get: { value }, set: {
        if case .reserved = zone { commit(min(max($0, 0), 512), to: zone) } else { commit(min(max($0, 0), 256), to: zone) }
      }),
      format: .number.precision(.fractionLength(0...1))
    )
    .labelsHidden()
    .monospacedDigit()
    .multilineTextAlignment(.center)
    .textFieldStyle(.roundedBorder)
    .controlSize(.small)
    .frame(width: Self.fieldWidth)
    .focused($focused, equals: zone)
    .onHover { hovered = $0 ? zone : (hovered == zone ? nil : hovered) }
    .help(label)
    .accessibilityLabel(label)
    // Search reveals the reserved areas here, where they are edited.
    .id(searchAnchor(zone))
  }

  private func searchAnchor(_ zone: SpacingZone) -> AnyHashable {
    switch zone {
    case .reserved(let top): AnyHashable(SettingsSearchAnchor.option(top ? .reservedTop : .reservedBottom))
    default: AnyHashable(zone)
    }
  }

  private func commit(_ value: Double, to zone: SpacingZone) {
    switch zone {
    case .reserved(let top):
      model.set(table: "layout", key: top ? "reserved_top" : "reserved_bottom", value: String(value))
    case .between: model.setWindowGap(value)
    case .edge(let edge): model.setScreenMargin(value, edges: linkedEdges(edge))
    }
  }

  private func linkedEdges(_ edge: ScreenEdge) -> [ScreenEdge] {
    switch edge {
    case .left, .right: linked(model.linksHorizontalEdges, .left, .right) ? [.left, .right] : [edge]
    case .top, .bottom: linked(model.linksVerticalEdges, .top, .bottom) ? [.top, .bottom] : [edge]
    }
  }

  private func linked(_ choice: Bool?, _ first: ScreenEdge, _ second: ScreenEdge) -> Bool {
    let layout = model.config.layout
    return choice ?? (first.value(in: layout) == second.value(in: layout))
  }

  private func linkBinding(_ choice: Binding<Bool?>, edges: [ScreenEdge]) -> Binding<Bool> {
    Binding(
      get: { linked(choice.wrappedValue, edges[0], edges[1]) },
      set: { isOn in
        choice.wrappedValue = isOn
        let layout = model.config.layout
        if isOn, edges[0].value(in: layout) != edges[1].value(in: layout) {
          model.setScreenMargin(edges[0].value(in: layout), edges: edges)
        }
      }
    )
  }
}

struct SpacingGeometry {
  struct Anchor {
    let zone: SpacingZone
    let point: CGPoint
  }

  private static let focusedID = WindowID(rawValue: 1)
  static let minimumBar = 12.0

  /// The configured top and bottom reserved space, for drawing an empty band apart from a used one.
  var reserved: (top: Double, bottom: Double) = (0, 0)

  var windows: [(frame: CGRect, focused: Bool)] = []
  var zones: [(SpacingZone, [CGRect])] = []
  var anchors: [Anchor] = []
  let borderWidth: Double
  let borderOutset: Double
  let showsInactiveBorders: Bool
  let borderColor: String
  let inactiveBorderColor: String

  init(config: Config, size: CGSize) {
    let borders = config.decorations.borders
    borderWidth = borders.enabled ? borders.width : 0
    borderOutset = borders.placement == "outside" ? borderWidth : 0
    showsInactiveBorders = borders.inactiveEnabled
    borderColor = borders.color
    inactiveBorderColor = borders.inactiveColor

    let workspace = Workspace(
      id: WorkspaceID(rawValue: "preview"),
      columns: [
        Column(window: Self.focusedID, width: .fraction(0.5)),
        Column(windows: [WindowID(rawValue: 2), WindowID(rawValue: 3)], focusedWindow: 0, width: .fraction(0.5)),
      ]
    )
    let layout = config.layout
    // Drawn to scale between a band thick enough to read as a bar, even when empty, and one that still
    // leaves room for the windows.
    let reservedTop = min(max(layout.reservedTop, Self.minimumBar), 36)
    let reservedBottom = min(max(layout.reservedBottom, Self.minimumBar), 36)
    let frames = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: reservedTop, width: size.width, height: size.height - reservedTop - reservedBottom),
      settings: LayoutSettings(config: config)
    ).map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
    guard frames.count == 3 else { return }
    reserved = (layout.reservedTop, layout.reservedBottom)
    windows = frames.enumerated().map { ($0.element, $0.offset == 0) }

    let outer = frames.map { $0.insetBy(dx: -borderOutset, dy: -borderOutset) }
    let top = ScreenEdge.top.value(in: layout)
    let right = ScreenEdge.right.value(in: layout)
    let bottom = ScreenEdge.bottom.value(in: layout)
    let left = ScreenEdge.left.value(in: layout)
    let columnGap = CGRect(
      x: outer[0].maxX, y: outer[0].minY, width: outer[1].minX - outer[0].maxX, height: outer[0].height
    )
    let usableBottom = size.height - reservedBottom
    zones = [
      (.reserved(top: true), [CGRect(x: 0, y: 0, width: size.width, height: reservedTop)]),
      (.reserved(top: false), [CGRect(x: 0, y: usableBottom, width: size.width, height: reservedBottom)]),
      (.edge(.top), [CGRect(x: 0, y: reservedTop, width: size.width, height: top)]),
      (.edge(.bottom), [CGRect(x: 0, y: usableBottom - bottom, width: size.width, height: bottom)]),
      (.edge(.left), [CGRect(x: 0, y: 0, width: left, height: size.height)]),
      (.edge(.right), [CGRect(x: size.width - right, y: 0, width: right, height: size.height)]),
      (.between, [
        columnGap,
        CGRect(x: outer[1].minX, y: outer[1].maxY, width: outer[1].width, height: outer[2].minY - outer[1].maxY),
      ]),
    ]
    // Leaders start at the middle of each space, so a zero margin starts on the screen outline.
    anchors = [
      Anchor(zone: .edge(.top), point: CGPoint(x: outer[0].midX, y: reservedTop + top / 2)),
      Anchor(zone: .edge(.bottom), point: CGPoint(x: outer[0].midX, y: usableBottom - bottom / 2)),
      Anchor(zone: .reserved(top: true), point: CGPoint(x: size.width - 70, y: reservedTop / 2)),
      Anchor(zone: .reserved(top: false), point: CGPoint(x: size.width - 70, y: size.height - reservedBottom / 2)),
      Anchor(zone: .edge(.left), point: CGPoint(x: left / 2, y: size.height / 2)),
      Anchor(zone: .edge(.right), point: CGPoint(x: size.width - right / 2, y: size.height / 2)),
      // Below the stacked-window gap, so the value never lines up with it and the right edge.
      Anchor(zone: .between, point: CGPoint(x: columnGap.midX, y: columnGap.minY + columnGap.height * 0.75)),
    ]
  }
}

/// The diagram and its leader lines, eased between configs so a changed value slides into place.
private struct SpacingDrawing: View, Animatable {
  let config: Config
  var vector: AnimatableVector
  let active: Set<SpacingZone>

  nonisolated var animatableData: AnimatableVector {
    get { vector }
    set { vector = newValue }
  }

  /// The gap, the four margins, then the border width and its outside placement.
  static func vector(_ config: Config) -> AnimatableVector {
    let layout = config.layout
    let borders = config.decorations.borders
    return AnimatableVector(values: [layout.gaps] + [ScreenEdge.top, .right, .bottom, .left].map { $0.value(in: layout) }
      + [borders.enabled ? borders.width : 0, borders.placement == "outside" ? 1 : 0,
        layout.reservedTop, layout.reservedBottom])
  }

  var body: some View {
    var config = config
    config.layout.gaps = max(0, vector[0])
    config.layout.outerTopGap = max(0, vector[1])
    config.layout.outerRightGap = max(0, vector[2])
    config.layout.outerBottomGap = max(0, vector[3])
    config.layout.outerLeftGap = max(0, vector[4])
    config.decorations.borders.width = max(0, vector[5])
    config.decorations.borders.placement = vector[6] > 0.5 ? "outside" : "inside"
    config.layout.reservedTop = max(0, vector[7])
    config.layout.reservedBottom = max(0, vector[8])
    let size = SpacingEditor.screenSize
    let geometry = SpacingGeometry(config: config, size: size)
    let callouts = geometry.anchors.map { SpacingEditor.Callout(anchor: $0, screen: size) }
    let active = active
    return Canvas { context, _ in
      context.translateBy(x: SpacingEditor.margin.width, y: SpacingEditor.margin.height)
      drawSpacingDiagram(geometry, active: active, size: size, in: &context)
      for callout in callouts {
        let color: Color = active.contains(callout.zone) ? .accentColor : .white.opacity(0.35)
        var leader = Path()
        leader.addLines(callout.leader)
        context.stroke(leader, with: .color(color), lineWidth: 1)
        let dot = callout.leader[0]
        context.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(color))
      }
    }
  }
}

private func drawSpacingDiagram(
  _ geometry: SpacingGeometry, active: Set<SpacingZone>, size: CGSize, in context: inout GraphicsContext
) {
  let screen = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
  context.fill(screen, with: .color(.black.opacity(0.3)))
  for (zone, rects) in geometry.zones {
    guard case .reserved(let top) = zone, let rect = rects.first else { continue }
    drawReservedBar(rect, used: (top ? geometry.reserved.top : geometry.reserved.bottom) > 0, in: &context)
  }
  for (zone, rects) in geometry.zones where active.contains(zone) {
    for rect in rects where rect.width >= 0.5 && rect.height >= 0.5 {
      context.fill(Path(rect), with: .color(.accentColor.opacity(0.35)))
      hatch(rect, in: context)
    }
  }
  for (index, window) in geometry.windows.enumerated() {
    drawSettingsMockWindow(in: &context, rect: window.frame, radius: 5, tint: [Color.blue, .orange, .green][index % 3],
      shadow: false)
    let outset = geometry.borderOutset
    let width = geometry.borderWidth
    if width > 0.05, window.focused || geometry.showsInactiveBorders {
      let band = window.frame.insetBy(dx: -outset + width / 2, dy: -outset + width / 2)
      context.stroke(
        Path(roundedRect: band, cornerRadius: 5 + outset - width / 2),
        with: .color(settingsColor(window.focused ? geometry.borderColor : geometry.inactiveBorderColor)),
        lineWidth: width
      )
    } else if outset > 0 {
      // The space stays reserved for a border that only appears on focus.
      context.stroke(
        Path(roundedRect: window.frame.insetBy(dx: -outset, dy: -outset), cornerRadius: 5 + outset),
        with: .color(.white.opacity(0.3)),
        style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])
      )
    }
  }
  context.stroke(screen, with: .color(.white.opacity(0.3)), lineWidth: 1)
}

/// A status bar in the reserved band; an empty band is only its dashed outline.
private func drawReservedBar(_ rect: CGRect, used: Bool, in context: inout GraphicsContext) {
  let band = rect.insetBy(dx: 3, dy: 2)
  let shape = Path(roundedRect: band, cornerRadius: min(4, band.height / 2))
  guard used else {
    context.stroke(shape, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
    return
  }
  context.fill(shape, with: .color(.white.opacity(0.14)))
  let item = min(band.height - 4, 6)
  let y = band.midY - item / 2
  for index in 0..<3 {
    let dot = CGRect(x: band.minX + 6 + CGFloat(index) * (item + 4), y: y, width: item, height: item)
    context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(index == 0 ? 0.7 : 0.3)))
  }
  let clock = CGRect(x: band.maxX - 6 - item * 4, y: y, width: item * 4, height: item)
  context.fill(Path(roundedRect: clock, cornerRadius: item / 2), with: .color(.white.opacity(0.3)))
}

private func hatch(_ rect: CGRect, in context: GraphicsContext) {
  var layer = context
  layer.clip(to: Path(rect))
  var lines = Path()
  for offset in stride(from: rect.minX - rect.height, through: rect.maxX, by: 5) {
    lines.move(to: CGPoint(x: offset, y: rect.maxY))
    lines.addLine(to: CGPoint(x: offset + rect.height, y: rect.minY))
  }
  layer.stroke(lines, with: .color(.accentColor), lineWidth: 0.75)
}

private extension ScreenEdge {
  var name: String {
    switch self {
    case .top: "Top"
    case .right: "Right"
    case .bottom: "Bottom"
    case .left: "Left"
    }
  }

  var title: String { "\(name) edge" }
}
