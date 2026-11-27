import DefiConfig
import DefiCore
import DefiModel
import SwiftUI
import DefiMacOS

/// The strip as the layout engine places it, with the focused border and unfocused dimming the
/// current config draws. Changes ease in rather than jump.
struct SettingsBorderPreview: View {
  let config: Config

  var body: some View {
    let vector = Self.vector(config)
    BorderPreviewCanvas(config: config, vector: vector)
      .animation(.smooth(duration: 0.3), value: vector)
      // The strip runs past both edges of the display; fade it out there.
      .mask {
        LinearGradient(
          stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
            .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
          startPoint: .leading, endPoint: .trailing)
      }
      .settingsStage(height: 270)
      .accessibilityElement()
      .accessibilityLabel("Preview of window borders")
  }

  /// Border width, unfocused border opacity, dim, outside placement, both colors, then the gaps.
  static func vector(_ config: Config) -> AnimatableVector {
    let borders = config.decorations.borders
    let layout = config.layout
    return AnimatableVector(values: [
      borders.enabled ? borders.width : 0, borders.inactiveEnabled ? 1 : 0, borders.inactiveDim,
      borders.placement == "outside" ? 1 : 0,
    ] + settingsColorComponents(borders.color) + settingsColorComponents(borders.inactiveColor) + [
      layout.gaps, ScreenEdge.top.value(in: layout), ScreenEdge.bottom.value(in: layout),
    ])
  }
}

private struct BorderPreviewCanvas: View, Animatable {
  let config: Config
  var vector: AnimatableVector

  nonisolated var animatableData: AnimatableVector {
    get { vector }
    set { vector = newValue }
  }

  var body: some View {
    Canvas { context, size in draw(in: &context, size: size) }
  }

  /// Lays out four columns on a small virtual display, so gaps and borders stay legible.
  private func draw(in context: inout GraphicsContext, size: CGSize) {
    var config = config
    config.decorations.borders.width = max(0, vector[0])
    config.decorations.borders.enabled = vector[0] > 0.01
    config.decorations.borders.placement = vector[3] > 0.5 ? "outside" : "inside"
    config.layout.gaps = max(0, vector[12])
    config.layout.outerTopGap = max(0, vector[13])
    config.layout.outerBottomGap = max(0, vector[14])

    let screen = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 18)
    let scale = screen.width / 860
    let viewport = Rect(x: 0, y: 0, width: 860, height: screen.height / scale)
    let ids = (1...4).map { WindowID(rawValue: UInt64($0)) }
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "preview"),
      columns: ids.map { Column(window: $0, width: .fraction(0.36)) }
    )
    let frames = computeLayout(workspace: workspace, viewport: viewport, settings: LayoutSettings(config: config))
    let focusedID = ids[1]
    // Center the focused column, with a neighbour running past each edge as in the strip.
    let focusedFrame = frames.first { $0.windowID == focusedID }?.frame
    let shift = screen.midX - ((focusedFrame?.x ?? 0) + (focusedFrame?.width ?? 0) / 2) * scale
    let radius = 12 * scale
    let width = vector[0] * scale
    let outsideness = min(max(vector[3], 0), 1)
    for (index, assignment) in frames.enumerated() {
      let rect = CGRect(
        x: screen.minX + assignment.frame.x * scale + shift, y: screen.minY + assignment.frame.y * scale,
        width: assignment.frame.width * scale, height: assignment.frame.height * scale)
      let focused = assignment.windowID == focusedID
      drawSettingsMockWindow(in: &context, rect: rect, radius: radius, tint: Self.tints[index % Self.tints.count])
      if !focused, vector[2] > 0 {
        context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(.black.opacity(min(vector[2], 0.95))))
      }
      let opacity = focused ? 1 : min(max(vector[1], 0), 1)
      guard width > 0.05, opacity > 0.01 else { continue }
      let outset = width * outsideness
      let band = rect.insetBy(dx: width / 2 - outset, dy: width / 2 - outset)
      let color = settingsColor(components: focused ? vector.values[4..<8] : vector.values[8..<12])
      context.stroke(
        Path(roundedRect: band, cornerRadius: radius + outset - width / 2),
        with: .color(color.opacity(opacity)), lineWidth: width)
    }
  }

  private static let tints: [Color] = [.green, .blue, .orange, .purple]
}
