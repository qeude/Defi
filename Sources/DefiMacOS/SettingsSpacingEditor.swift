import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import SwiftUI

enum SpacingZone: Hashable {
  case edge(ScreenEdge)
  case between
}

/// A screen laid out by the real layout engine at actual point size. Each spacing value is a
/// dimension callout outside the screen, joined to its space by a leader line. Focusing or
/// hovering a value highlights every space it controls.
@MainActor
struct SpacingEditor: View {
  let model: DefiSettingsModel
  @State private var hovered: SpacingZone?
  @SwiftUI.FocusState private var focused: SpacingZone?

  private static let screenSize = CGSize(width: 400, height: 220)
  private static let margin = CGSize(width: 84, height: 44)
  /// Distance from the screen outline to a callout's center line.
  private nonisolated static let reach = 26.0
  private nonisolated static let fieldWidth = 40.0

  var body: some View {
    let geometry = SpacingGeometry(config: model.config, size: Self.screenSize)
    let callouts = geometry.anchors.map { Callout(anchor: $0, screen: Self.screenSize) }
    let active = activeZones
    VStack(spacing: 10) {
      ZStack(alignment: .topLeading) {
        SpacingDiagram(geometry: geometry, active: active)
          .frame(width: Self.screenSize.width, height: Self.screenSize.height)
          .offset(x: Self.margin.width, y: Self.margin.height)
          .accessibilityHidden(true)
        Canvas { context, _ in
          context.translateBy(x: Self.margin.width, y: Self.margin.height)
          for callout in callouts {
            let color: Color = active.contains(callout.zone) ? .accentColor : .secondary.opacity(0.6)
            var leader = Path()
            leader.addLines(callout.leader)
            context.stroke(leader, with: .color(color), lineWidth: 1)
            let dot = callout.leader[0]
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 2, y: dot.y - 2, width: 4, height: 4)), with: .color(color))
          }
        }
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
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func calloutControls(_ callout: Callout) -> some View {
    let origin = CGPoint(x: Self.margin.width, y: Self.margin.height)
    let field = CGPoint(x: origin.x + callout.field.x, y: origin.y + callout.field.y)
    switch callout.zone {
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
  private struct Callout {
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
      }
    }
  }

  private var activeZones: Set<SpacingZone> {
    switch focused ?? hovered {
    case nil: []
    case .between: [.between]
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
    case .edge(let edge):
      value = edge.value(in: layout)
      label = edge.title
    }
    return TextField(
      label,
      value: Binding(get: { value }, set: { commit(min(max($0, 0), 256), to: zone) }),
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
  }

  private func commit(_ value: Double, to zone: SpacingZone) {
    switch zone {
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

  /// Linking copies the first edge onto the second so both values agree immediately.
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
    let frames = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: size.width, height: size.height),
      settings: LayoutSettings(config: config)
    ).map { CGRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
    guard frames.count == 3 else { return }
    windows = frames.enumerated().map { ($0.element, $0.offset == 0) }

    let outer = frames.map { $0.insetBy(dx: -borderOutset, dy: -borderOutset) }
    let layout = config.layout
    let top = ScreenEdge.top.value(in: layout)
    let right = ScreenEdge.right.value(in: layout)
    let bottom = ScreenEdge.bottom.value(in: layout)
    let left = ScreenEdge.left.value(in: layout)
    let columnGap = CGRect(
      x: outer[0].maxX, y: outer[0].minY, width: outer[1].minX - outer[0].maxX, height: outer[0].height
    )
    zones = [
      (.edge(.top), [CGRect(x: 0, y: 0, width: size.width, height: top)]),
      (.edge(.bottom), [CGRect(x: 0, y: size.height - bottom, width: size.width, height: bottom)]),
      (.edge(.left), [CGRect(x: 0, y: 0, width: left, height: size.height)]),
      (.edge(.right), [CGRect(x: size.width - right, y: 0, width: right, height: size.height)]),
      (.between, [
        columnGap,
        CGRect(x: outer[1].minX, y: outer[1].maxY, width: outer[1].width, height: outer[2].minY - outer[1].maxY),
      ]),
    ]
    // Leaders start at the middle of each space, so a zero margin starts on the screen outline.
    anchors = [
      Anchor(zone: .edge(.top), point: CGPoint(x: outer[0].midX, y: top / 2)),
      Anchor(zone: .edge(.bottom), point: CGPoint(x: outer[0].midX, y: size.height - bottom / 2)),
      Anchor(zone: .edge(.left), point: CGPoint(x: left / 2, y: size.height / 2)),
      Anchor(zone: .edge(.right), point: CGPoint(x: size.width - right / 2, y: size.height / 2)),
      // Below the stacked-window gap, so the value never lines up with it and the right edge.
      Anchor(zone: .between, point: CGPoint(x: columnGap.midX, y: columnGap.minY + columnGap.height * 0.75)),
    ]
  }
}

struct SpacingDiagram: View {
  let geometry: SpacingGeometry
  let active: Set<SpacingZone>

  var body: some View {
    Canvas { context, size in
      let screen = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
      context.fill(screen, with: .color(.primary.opacity(0.04)))

      for (zone, rects) in geometry.zones where active.contains(zone) {
        for rect in rects where rect.width >= 0.5 && rect.height >= 0.5 {
          context.fill(Path(rect), with: .color(.accentColor.opacity(0.15)))
          hatch(rect, in: context)
        }
      }

      for window in geometry.windows {
        let path = Path(roundedRect: window.frame, cornerRadius: 5)
        context.fill(path, with: .color(Color(nsColor: .controlBackgroundColor)))
        context.stroke(path, with: .color(.primary.opacity(0.3)), lineWidth: 1)
        let outset = geometry.borderOutset
        let width = geometry.borderWidth
        if width > 0, window.focused || geometry.showsInactiveBorders {
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
            with: .color(.primary.opacity(0.3)),
            style: StrokeStyle(lineWidth: 0.75, dash: [2, 2])
          )
        }
      }
      context.stroke(screen, with: .color(.primary.opacity(0.35)), lineWidth: 1)
    }
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
