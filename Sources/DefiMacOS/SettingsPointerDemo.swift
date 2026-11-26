import DefiConfig
import SwiftUI

/// What the trackpad demo plays: the gesture setting under the pointer.
enum SettingsPointerDemo: Hashable {
  case swipe
  case overview
}

/// A looping illustration in the manner of System Settings' trackpad videos, drawn live from the
/// configuration: turning a setting off shows what happens without it. Still when motion is reduced
/// or the window is inactive.
struct SettingsPointerDemoView: View {
  let demo: SettingsPointerDemo
  let input: InputConfig
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var activeState
  @Environment(SettingsPageVisibility.self) private var visibility: SettingsPageVisibility?

  private static let period = 4.0

  var body: some View {
    ZStack {
      // Each demo is its own layer, so switching demos crossfades instead of cutting.
      scene(demo).id(demo).transition(.opacity)
    }
    .animation(.easeInOut(duration: 0.3), value: demo)
    .settingsStage(height: 210)
    .accessibilityElement()
    .accessibilityLabel(accessibilityText)
  }

  private func scene(_ demo: SettingsPointerDemo) -> some View {
    TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || activeState == .inactive || visibility?.visible == false)) { timeline in
      let time = reduceMotion ? Self.period * 0.45 : timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        draw(demo, in: &context, size: size, phase: time.truncatingRemainder(dividingBy: Self.period) / Self.period)
      }
    }
  }

  private var accessibilityText: String {
    switch demo {
    case .swipe: "Demo: \(input.scrollGestureFingers) fingers swipe the strip"
    case .overview: input.overviewGesture ? "Demo: \(input.overviewGestureFingers) fingers swipe up for the Overview"
      : "The Overview swipe is off"
    }
  }

  // MARK: Scene

  private func draw(_ demo: SettingsPointerDemo, in context: inout GraphicsContext, size: CGSize, phase: Double) {
    // A display beside a Magic Trackpad, both at their real proportions.
    let height = size.height - 44
    let display = CGSize(width: height * 1.6, height: height)
    let pad = CGSize(width: height * 0.8 * 1.42, height: height * 0.8)
    let left = (size.width - display.width - 40 - pad.width) / 2
    drawGestureScene(demo, in: &context,
      display: CGRect(origin: CGPoint(x: left, y: 22), size: display),
      pad: CGRect(origin: CGPoint(x: left + display.width + 40, y: 22 + (height - pad.height) / 2), size: pad),
      phase: phase)
  }

  private func drawGestureScene(
    _ demo: SettingsPointerDemo, in context: inout GraphicsContext, display: CGRect, pad: CGRect, phase: Double
  ) {
    var strip = StripState(offset: 0, focused: 1, scale: 1)
    var touch: CGPoint
    var start: CGPoint
    var touching: Bool
    var fingers = input.scrollGestureFingers
    switch demo {
    case .swipe:
      let (travel, moving) = Self.swipe(phase)
      if input.scrollGestures {
        strip.offset = travel * (input.scrollGestureSnap ? 1 : 0.6)
        strip.focused = 1 + Int(strip.offset.rounded())
      }
      touching = moving
      touch = CGPoint(x: 0.7 - travel * 0.4, y: 0.5)
      start = CGPoint(x: phase < 0.5 ? 0.7 : 0.3, y: 0.5)
    case .overview:
      fingers = input.overviewGestureFingers
      let up = Self.smooth(Self.window(phase, 0.1, 0.35))
      let down = Self.smooth(Self.window(phase, 0.6, 0.85))
      if input.overviewGesture { strip.scale = 1 - 0.42 * up * (1 - down) }
      touching = (0.1..<0.35).contains(phase) || (0.6..<0.85).contains(phase)
      touch = CGPoint(x: 0.5, y: phase < 0.5 ? 0.74 - 0.48 * up : 0.26 + 0.48 * down)
      start = CGPoint(x: 0.5, y: phase < 0.5 ? 0.74 : 0.26)
    }
    drawDisplay(in: &context, display: display, strip: strip)
    let enabled = demo == .swipe ? input.scrollGestures : input.overviewGesture
    drawTrackpad(in: &context, pad: pad, fingers: fingers, touch: touch, from: start, touching: touching,
      enabled: enabled)
  }

  // MARK: Parts

  private struct StripState {
    var offset: Double
    var focused: Int
    var scale: Double
  }

  private func drawDisplay(in context: inout GraphicsContext, display: CGRect, strip: StripState) {
    let bezel = Path(roundedRect: display, cornerRadius: 10)
    context.fill(bezel, with: .color(Color(hex: 0x0D0E12)))
    let screen = display.insetBy(dx: 5, dy: 5)
    var inner = context
    inner.clip(to: Path(roundedRect: screen, cornerRadius: 6))
    inner.fill(Path(screen), with: .linearGradient(
      Gradient(colors: [Color(hex: 0x14295F), Color(hex: 0x0B1330)]),
      startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
    drawStrip(in: &inner, screen: screen, state: strip)
    context.stroke(bezel, with: .color(.white.opacity(0.14)), lineWidth: 1)
  }

  /// Five columns, the second centered at rest; `offset` is in columns.
  private func drawStrip(in context: inout GraphicsContext, screen: CGRect, state: StripState) {
    let gap: CGFloat = 5
    let width = screen.width * 0.44 * state.scale
    let height = (screen.height - 16) * state.scale
    let pitch = width + gap * state.scale
    let originX = screen.midX - width / 2 - pitch * (1 + state.offset)
    let y = screen.midY - height / 2
    for index in 0..<5 {
      let rect = CGRect(x: originX + CGFloat(index) * pitch, y: y, width: width, height: height)
      drawSettingsMockWindow(in: &context, rect: rect, radius: 6 * state.scale,
        tint: [Color.green, .blue, .orange, .purple, .pink][index], shadow: false)
      if index == state.focused {
        context.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 7.5 * state.scale),
          with: .color(.white), lineWidth: 2)
      } else {
        context.fill(Path(roundedRect: rect, cornerRadius: 6 * state.scale), with: .color(.black.opacity(0.35)))
      }
    }
    if state.scale < 0.98 {
      // The Overview shows the next workspace below.
      let shown = (1 - state.scale) / 0.42
      let below = CGRect(x: screen.midX - width * 1.6, y: y + height + 8, width: width * 3.2, height: height * 0.45)
      context.fill(Path(roundedRect: below, cornerRadius: 5), with: .color(.white.opacity(0.12 * shown)))
    }
  }

  /// A silver Magic Trackpad; the fingertips leave a short trail along the swipe while they move.
  private func drawTrackpad(
    in context: inout GraphicsContext, pad: CGRect, fingers: Int, touch: CGPoint, from start: CGPoint,
    touching: Bool, enabled: Bool
  ) {
    let shape = Path(roundedRect: pad, cornerRadius: pad.height * 0.09, style: .continuous)
    var shadowed = context
    shadowed.addFilter(.shadow(color: .black.opacity(0.5), radius: 12, y: 6))
    shadowed.fill(shape, with: .linearGradient(
      Gradient(colors: [Color(hex: 0xE9EAED), Color(hex: 0xC6C8CD)]),
      startPoint: CGPoint(x: pad.midX, y: pad.minY), endPoint: CGPoint(x: pad.midX, y: pad.maxY)))
    context.stroke(Path(roundedRect: pad.insetBy(dx: 0.5, dy: 0.5), cornerRadius: pad.height * 0.09, style: .continuous),
      with: .color(.white.opacity(0.7)), lineWidth: 1)
    let count = max(fingers, 1)
    let spread = pad.width * 0.085
    func point(_ unit: CGPoint) -> CGPoint {
      CGPoint(x: pad.minX + pad.width * unit.x, y: pad.minY + pad.height * unit.y)
    }
    let center = point(touch)
    let origin = point(start)
    let alpha = enabled ? 1.0 : 0.45
    for finger in 0..<count {
      let offset = CGFloat(finger) - CGFloat(count - 1) / 2
      // Fingertips arc like a hand: outer fingers sit a little lower.
      let shift = CGPoint(x: offset * spread, y: abs(offset) * spread * 0.22)
      if touching {
        var trail = Path()
        trail.move(to: CGPoint(x: origin.x + shift.x, y: origin.y + shift.y))
        trail.addLine(to: CGPoint(x: center.x + shift.x, y: center.y + shift.y))
        context.stroke(trail, with: .color(Color.accentColor.opacity(0.35 * alpha)),
          style: StrokeStyle(lineWidth: spread * 0.62, lineCap: .round))
      }
      let tip = CGRect(x: center.x + shift.x - spread * 0.36, y: center.y + shift.y - spread * 0.36,
        width: spread * 0.72, height: spread * 0.72)
      var finger = context
      finger.addFilter(.shadow(color: .black.opacity(0.3), radius: 2, y: 1))
      finger.fill(Path(ellipseIn: tip), with: .color(Color(hex: 0x2F6BFF).opacity((touching ? 0.95 : 0.55) * alpha)))
    }
  }

  // MARK: Timing

  /// Strip travel in columns and whether fingers move: left during the first half, back during the second.
  private static func swipe(_ phase: Double) -> (Double, Bool) {
    if phase < 0.5 {
      return (smooth(window(phase, 0.08, 0.32)), (0.08..<0.32).contains(phase))
    }
    return (1 - smooth(window(phase, 0.58, 0.82)), (0.58..<0.82).contains(phase))
  }

  private static func window(_ phase: Double, _ start: Double, _ end: Double) -> Double {
    min(max((phase - start) / (end - start), 0), 1)
  }

  private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
