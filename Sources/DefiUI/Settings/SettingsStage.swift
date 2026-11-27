import AppKit
import SwiftUI
import DefiMacOS

/// Defi's wallpaper from the site's desk: navy lit by the icon's blue. Every Settings preview sits on
/// it, so the previews read as one set. Drawn, not the user's wallpaper: that file can sit in a
/// protected folder, and reading it would ask for access.
struct SettingsStageBackground: View {
  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(hex: 0x0A1024), Color(hex: 0x0C1A3D), Color(hex: 0x0B0A16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      RadialGradient(colors: [Color(hex: 0x1D4FD8).opacity(0.8), .clear],
        center: UnitPoint(x: 0.15, y: 1.05), startRadius: 0, endRadius: 340)
      RadialGradient(colors: [Color(hex: 0x2B6DF2).opacity(0.7), .clear],
        center: UnitPoint(x: 0.9, y: 0), startRadius: 0, endRadius: 300)
      RadialGradient(colors: [Color(hex: 0x54AFFF).opacity(0.35), .clear],
        center: UnitPoint(x: 0.62, y: 0.62), startRadius: 0, endRadius: 220)
    }
  }
}

extension View {
  /// A preview filling the top of its card on the shared stage, in the dark appearance the stage needs.
  func settingsStage(height: CGFloat) -> some View {
    frame(maxWidth: .infinity)
      .frame(height: height)
      .background(SettingsStageBackground())
      .environment(\.colorScheme, .dark)
      .clipped()
      .settingsEdgeToEdge()
  }
}

extension Color {
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}

/// A dark app window, the same in every preview: traffic lights, a sidebar and a tinted header.
func drawSettingsMockWindow(
  in context: inout GraphicsContext, rect: CGRect, radius: CGFloat, tint: Color, shadow: Bool = true, dot: CGFloat? = nil
) {
  let shape = Path(roundedRect: rect, cornerRadius: radius)
  if shadow {
    var shadowed = context
    shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 10, y: 4))
    shadowed.fill(shape, with: .color(Color(hex: 0x1E1F24)))
  } else {
    context.fill(shape, with: .color(Color(hex: 0x1E1F24)))
  }
  var inner = context
  inner.clip(to: shape)
  let sidebar = CGRect(x: rect.minX, y: rect.minY, width: rect.width * 0.26, height: rect.height)
  inner.fill(Path(sidebar), with: .color(.white.opacity(0.05)))
  let dot = dot ?? min(7, rect.height / 14)
  for (index, color) in [Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)].enumerated() {
    let frame = CGRect(x: rect.minX + dot * 1.3 + CGFloat(index) * dot * 1.45, y: rect.minY + dot * 1.3, width: dot, height: dot)
    inner.fill(Path(ellipseIn: frame), with: .color(color))
  }
  let top = rect.minY + dot * 4
  for row in 0..<4 {
    let item = CGRect(x: sidebar.minX + dot * 1.3, y: top + CGFloat(row) * dot * 1.9, width: sidebar.width - dot * 2.6, height: dot * 0.8)
    guard item.maxY < rect.maxY - dot else { break }
    inner.fill(Path(roundedRect: item, cornerRadius: dot * 0.4), with: .color(.white.opacity(row == 0 ? 0.22 : 0.1)))
  }
  let content = CGRect(x: sidebar.maxX + dot * 1.4, y: top, width: rect.width - sidebar.width - dot * 2.8, height: rect.maxY - top - dot)
  let hero = CGRect(x: content.minX, y: content.minY, width: content.width, height: min(dot * 6, content.height * 0.4))
  inner.fill(Path(roundedRect: hero, cornerRadius: dot * 0.8), with: .color(tint.opacity(0.4)))
  for line in 0..<3 {
    let bar = CGRect(x: content.minX, y: hero.maxY + dot * 1.4 + CGFloat(line) * dot * 1.5,
      width: content.width * (line == 2 ? 0.55 : 0.9), height: dot * 0.7)
    guard bar.maxY < content.maxY else { break }
    inner.fill(Path(roundedRect: bar, cornerRadius: dot * 0.35), with: .color(.white.opacity(0.1)))
  }
}

/// Values a preview interpolates between configs, so a change slides instead of jumping.
struct AnimatableVector: VectorArithmetic {
  var values: [Double]

  static var zero: AnimatableVector { AnimatableVector(values: []) }

  static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
    combine(lhs, rhs, +)
  }

  static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
    combine(lhs, rhs, -)
  }

  mutating func scale(by rhs: Double) {
    values = values.map { $0 * rhs }
  }

  var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }

  subscript(index: Int) -> Double { index < values.count ? values[index] : 0 }

  private static func combine(
    _ lhs: AnimatableVector, _ rhs: AnimatableVector, _ operation: (Double, Double) -> Double
  ) -> AnimatableVector {
    let count = max(lhs.values.count, rhs.values.count)
    return AnimatableVector(values: (0..<count).map { operation(lhs[$0], rhs[$0]) })
  }
}

/// sRGB components of a config color, for interpolation.
func settingsColorComponents(_ value: String) -> [Double] {
  guard let color = NSColor(settingsColor(value)).usingColorSpace(.sRGB) else { return [1, 1, 1, 1] }
  return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map(Double.init)
}

func settingsColor(components: ArraySlice<Double>) -> Color {
  let values = Array(components)
  guard values.count == 4 else { return .white }
  return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: values[3])
}
