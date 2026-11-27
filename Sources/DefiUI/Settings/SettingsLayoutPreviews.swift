import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

/// The strip opening windows at the default width, then focus walking right: the scroll follows the
/// focused-column choice, and a lone column sits where the centering choice puts it.
struct SettingsColumnsPreview: View {
  let layout: LayoutConfig
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var activeState
  @Environment(SettingsPageVisibility.self) private var visibility: SettingsPageVisibility?

  var body: some View {
    let rules = "\(layout.centerFocusedColumn.rawValue)-\(layout.alwaysCenterSingleColumn)"
    ZStack {
      // A changed rule crossfades to the new motion; a changed width eases.
      ColumnsCanvas(layout: layout, width: layout.defaultColumnWidth, paused: reduceMotion || activeState == .inactive || visibility?.visible == false,
        frozen: reduceMotion)
        .id(rules)
        .transition(.opacity)
    }
    .animation(.easeInOut(duration: 0.3), value: rules)
    .animation(.smooth(duration: 0.35), value: layout.defaultColumnWidth)
    .settingsStage(height: 200)
    .accessibilityElement()
    .accessibilityLabel("Preview of new columns and how the strip follows focus")
  }

}

private struct ColumnsCanvas: View, Animatable {
  let layout: LayoutConfig
  var width: Double
  let paused: Bool
  let frozen: Bool

  nonisolated var animatableData: Double {
    get { width }
    set { width = newValue }
  }

  private static let period = 7.0
  /// Phase, window count and focused column of each beat.
  private static let beats: [(Double, Int, Int)] = [
    (0, 1, 0), (0.18, 4, 0), (0.34, 4, 1), (0.5, 4, 2), (0.66, 4, 3), (0.86, 1, 0),
  ]

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: paused)) { timeline in
      let time = frozen ? Self.period * 0.55 : timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        draw(in: &context, size: size, phase: time.truncatingRemainder(dividingBy: Self.period) / Self.period)
      }
    }
  }

  private func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
    // A 16:9 display, whatever the card's width.
    let displayWidth = min(size.width * 0.76, (size.height - 28) * 16 / 9)
    let display = CGRect(x: (size.width - displayWidth) / 2, y: 14, width: displayWidth, height: size.height - 28)
    context.fill(Path(roundedRect: display, cornerRadius: 10), with: .color(Color(hex: 0x0D0E12)))
    let screen = display.insetBy(dx: 5, dy: 5)
    var inner = context
    inner.clip(to: Path(roundedRect: screen, cornerRadius: 6))
    inner.fill(Path(screen), with: .linearGradient(
      Gradient(colors: [Color(hex: 0x14295F), Color(hex: 0x0B1330)]),
      startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))

    let margin: CGFloat = 6
    let width = (screen.width - 2 * margin) * CGFloat(min(max(width, 0.05), 1))
    let pitch = width + 5
    let scrolls = Self.scrolls(screen: screen.width, margin: margin, width: width, pitch: pitch, layout: layout)
    let (index, progress) = Self.beat(at: phase)
    let previous = Self.beats[max(index - 1, 0)]
    let current = Self.beats[index]
    let eased = Self.smooth(progress)
    let scroll = scrolls[max(index - 1, 0)] + (scrolls[index] - scrolls[max(index - 1, 0)]) * eased
    let height = screen.height - 2 * margin
    for column in 0..<4 {
      let was = column < previous.1 ? 1.0 : 0
      let now = column < current.1 ? 1.0 : 0
      let shown = was + (now - was) * eased
      guard shown > 0.01 else { continue }
      let rect = CGRect(x: screen.minX + scroll + CGFloat(column) * pitch, y: screen.minY + margin, width: width, height: height)
        .insetBy(dx: (1 - shown) * width * 0.08, dy: (1 - shown) * height * 0.08)
      var layer = inner
      layer.opacity = shown
      drawSettingsMockWindow(in: &layer, rect: rect, radius: 6, tint: [Color.blue, .orange, .green, .purple][column], shadow: false)
      let focusedNow = current.2 == column
      let focusedBefore = previous.2 == column
      let focus = (focusedBefore ? 1 - eased : 0) + (focusedNow ? eased : 0)
      if focus > 0.01 {
        layer.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 7.5),
          with: .color(.white.opacity(focus)), lineWidth: 2)
      }
      layer.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(.black.opacity(0.35 * (1 - focus))))
    }
    context.stroke(Path(roundedRect: display, cornerRadius: 10), with: .color(.white.opacity(0.14)), lineWidth: 1)

  }

  /// The strip's left edge on screen after each beat, by the configured rules.
  private static func scrolls(screen: CGFloat, margin: CGFloat, width: CGFloat, pitch: CGFloat, layout: LayoutConfig) -> [CGFloat] {
    var scroll: CGFloat = margin
    return beats.map { _, count, focused in
      let left = CGFloat(focused) * pitch
      if count == 1 {
        scroll = layout.alwaysCenterSingleColumn ? (screen - width) / 2 : margin
        return scroll
      }
      let visible = scroll + left >= margin - 0.5 && scroll + left + width <= screen - margin + 0.5
      switch layout.centerFocusedColumn {
      case .always:
        scroll = (screen - width) / 2 - left
      case .onOverflow:
        if !visible { scroll = (screen - width) / 2 - left }
      case .never:
        if scroll + left < margin { scroll = margin - left }
        if scroll + left + width > screen - margin { scroll = screen - margin - width - left }
      }
      return scroll
    }
  }

  private static func beat(at phase: Double) -> (Int, Double) {
    let index = beats.lastIndex { $0.0 <= phase } ?? 0
    return (index, min(max((phase - beats[index].0) / 0.08, 0), 1))
  }

  private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}

/// One display per preset, side by side. A width preset shows the focused column after its left
/// neighbor, scrolled the way the focused-column choice scrolls; a height preset shows a stacked column.
/// Hovering a chip singles its display out.
struct SettingsPresetsPreview: View {
  let kind: PresetKind
  let values: [Double]
  let held: Int?
  let centering: CenterFocusedColumn

  private static let tints: [Color] = [.blue, .indigo, .teal, .orange, .pink, .green]

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        let singled = held == index
        VStack(spacing: 8) {
          PresetDisplay(kind: kind, tint: Self.tints[index % Self.tints.count], outlined: singled,
            geometry: AnimatablePair(value, kind == .width ? Self.scroll(value, centering) : 0))
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: 168)
          Text("\(Int((value * 100).rounded()))%")
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(held == nil || singled ? .primary : .secondary)
        }
        .opacity(held == nil || singled ? 1 : 0.4)
      }
    }
    .padding(.horizontal, 20)
    .animation(.smooth(duration: 0.3), value: values)
    .animation(.smooth(duration: 0.3), value: centering)
    .animation(.smooth(duration: 0.2), value: held)
    .settingsStage(height: 170)
    .accessibilityElement()
    .accessibilityLabel("\(kind.name.capitalized) presets: "
      + values.map { "\(Int(($0 * 100).rounded())) percent" }.joined(separator: ", "))
  }

  /// The strip's left edge, in screen widths, once focus moves from a half-width column onto one of
  /// `width`: the same rules as the layout engine's focused-column choice.
  static func scroll(_ preset: Double, _ centering: CenterFocusedColumn) -> Double {
    let margin = PresetDisplay.margin
    let width = PresetDisplay.width(preset)
    let left = PresetDisplay.neighbor + PresetDisplay.gap
    let fits = margin + left + width <= 1 - margin
    let centered = (1 - width) / 2 - left
    switch centering {
    case .always: return centered
    case .onOverflow: return fits ? margin : centered
    case .never: return fits ? margin : 1 - margin - width - left
    }
  }
}

private struct PresetDisplay: View, Animatable {
  static let margin = 0.03
  static let gap = 0.02
  static let neighbor = width(0.5)

  /// A preset is a share of the width between the screen margins.
  static func width(_ preset: Double) -> Double { preset * (1 - 2 * margin) }

  let kind: PresetKind
  let tint: Color
  let outlined: Bool
  /// The preset, then the strip's scroll.
  var geometry: AnimatablePair<Double, Double>

  nonisolated var animatableData: AnimatablePair<Double, Double> {
    get { geometry }
    set { geometry = newValue }
  }

  var body: some View {
    Canvas { context, size in
      let display = CGRect(origin: .zero, size: size)
      context.fill(Path(roundedRect: display, cornerRadius: 8), with: .color(Color(hex: 0x0D0E12)))
      let screen = display.insetBy(dx: 4, dy: 4)
      var inner = context
      inner.clip(to: Path(roundedRect: screen, cornerRadius: 5))
      inner.fill(Path(screen), with: .linearGradient(
        Gradient(colors: [Color(hex: 0x14295F), Color(hex: 0x0B1330)]),
        startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
      let bar = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 5)
      inner.fill(Path(bar), with: .color(.black.opacity(0.35)))
      let area = CGRect(x: screen.minX, y: bar.maxY + 4, width: screen.width, height: screen.maxY - bar.maxY - 8)
      // One scale for every window on this display, whatever its height.
      let dot = area.height / 22
      if kind == .width { widths(in: &inner, area: area, dot: dot) } else { heights(in: &inner, area: area, dot: dot) }
      context.stroke(Path(roundedRect: display.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8),
        with: .color(.white.opacity(outlined ? 0.9 : 0.14)), lineWidth: outlined ? 1.5 : 1)
    }
  }

  private func widths(in context: inout GraphicsContext, area: CGRect, dot: CGFloat) {
    let unit = area.width
    let scroll = geometry.second
    let previous = CGRect(x: area.minX + scroll * unit, y: area.minY, width: Self.neighbor * unit, height: area.height)
    let focused = CGRect(x: previous.maxX + Self.gap * unit, y: area.minY, width: Self.width(geometry.first) * unit, height: area.height)
    let next = CGRect(x: focused.maxX + Self.gap * unit, y: area.minY, width: Self.neighbor * unit, height: area.height)
    window(in: &context, previous, tint: .gray, focused: false, dot: dot)
    window(in: &context, next, tint: .gray, focused: false, dot: dot)
    window(in: &context, focused, tint: tint, focused: true, dot: dot)
  }

  private func heights(in context: inout GraphicsContext, area: CGRect, dot: CGFloat) {
    let width = area.width * 0.42
    let gap = Self.gap * area.width
    let column = CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: area.height)
    let top = CGRect(x: column.minX, y: column.minY, width: width, height: (area.height - gap) * geometry.first)
    let bottom = CGRect(x: column.minX, y: top.maxY + gap, width: width, height: column.maxY - top.maxY - gap)
    window(in: &context, column.offsetBy(dx: -width - gap, dy: 0), tint: .gray, focused: false, dot: dot)
    window(in: &context, column.offsetBy(dx: width + gap, dy: 0), tint: .gray, focused: false, dot: dot)
    window(in: &context, bottom, tint: .gray, focused: false, dot: dot)
    window(in: &context, top, tint: tint, focused: true, dot: dot)
  }

  private func window(in context: inout GraphicsContext, _ rect: CGRect, tint: Color, focused: Bool, dot: CGFloat) {
    guard rect.height > 2 else { return }
    drawSettingsMockWindow(in: &context, rect: rect, radius: 3, tint: tint, shadow: false, dot: dot)
    if focused {
      context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 4), with: .color(.white), lineWidth: 1.5)
    } else {
      context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.black.opacity(0.45)))
    }
  }
}

/// Presets as a row of chips: one click edits a value, the plus adds one.
struct PresetChips: View {
  let kind: PresetKind
  let values: [Double]
  let save: ([Double]) -> Void
  @Binding var hovered: Int?
  @State private var editing: Int?

  var body: some View {
    HStack(spacing: 8) {
      ForEach(values.indices, id: \.self) { index in
        Button { editing = index } label: {
          Text("\(Int((values[index] * 100).rounded()))%")
            .font(.body.monospacedDigit().weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hovered == index || editing == index ? AnyShapeStyle(Color.accentColor.opacity(0.25))
              : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
          PresetEditor(kind: kind, values: values, index: index, save: save, close: { editing = nil })
        }
        .accessibilityLabel("Preset \(index + 1), \(Int((values[index] * 100).rounded())) percent")
        .accessibilityHint("Edit")
      }
      Spacer(minLength: 0)
    }
    .animation(.smooth(duration: 0.25), value: values)
  }
}

private struct PresetEditor: View {
  let kind: PresetKind
  let values: [Double]
  let index: Int
  let save: ([Double]) -> Void
  let close: () -> Void

  var body: some View {
    let value = values.indices.contains(index) ? values[index] * 100 : 50
    VStack(alignment: .leading, spacing: 10) {
      Text("Preset \(index + 1)").font(.headline)
      HStack {
        Slider(value: Binding(get: { value }, set: { update($0) }), in: 5...kind.maximum, step: 5)
          .accessibilityLabel("Preset \(index + 1) \(kind.name)")
        TextField(kind.name.capitalized, value: Binding(get: { value }, set: { update($0) }),
          format: .number.precision(.fractionLength(0...2)))
          .labelsHidden()
          .multilineTextAlignment(.trailing)
          .frame(width: 56)
        Text("%").foregroundStyle(.secondary)
      }
      Button(role: .destructive) {
        var values = values
        values.remove(at: index)
        close()
        save(values)
      } label: {
        Label("Remove Preset", systemImage: "trash")
      }
      .disabled(values.count == 1)
    }
    .padding(14)
    .frame(width: 280)
  }

  private func update(_ percentage: Double) {
    guard values.indices.contains(index), !PresetKind.duplicates(percentage, in: values, except: index) else { return }
    var values = values
    values[index] = percentage / 100
    save(values)
  }
}
