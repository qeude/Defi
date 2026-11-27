import AppKit
import CoreMedia
import CoreVideo
import DefiConfig
import DefiCore
import DefiModel
import OSLog
import QuartzCore
import ScreenCaptureKit
import Synchronization
import VideoToolbox


enum RibbonProxyDrag: Equatable {
  case idle
  case carrying(WindowID)
  /// A tiled window resized by the pointer: its proxy follows the native frame.
  case stretching(WindowID)
  /// Another display's carried window is over this one: it previews the drop here.
  case hosting(WindowID)
  case dropping(WindowID)
  /// A scroll gesture moves the whole ribbon.
  case panning

  var heldWindowID: WindowID? {
    switch self {
    case .carrying(let id), .stretching(let id), .hosting(let id): id
    case .idle, .dropping, .panning: nil
    }
  }
}


/// Global top-left coordinates to the overlay's layer space. The panel's layer tree
/// keeps AppKit's bottom-left origin (a layer-backed root is never geometry-flipped).
func ribbonProxyLocal(_ frame: Rect, in area: Rect) -> CGRect {
  CGRect(x: frame.x - area.x, y: area.y + area.height - frame.y - frame.height,
    width: frame.width, height: frame.height)
}

func ribbonProxyLocal(_ point: CGPoint, in area: Rect) -> CGPoint {
  CGPoint(x: point.x - area.x, y: area.y + area.height - point.y)
}

let ribbonProxyShadowPad: CGFloat = 36
let ribbonProxyRestingShadowOpacity: Float = 0.67
private let ribbonProxyShadowCorner: CGFloat = 12
/// A blurred rounded rectangle, nine-sliced over each window: drawn once, then only
/// stretched by the compositor.
let ribbonProxyShadowImage: CGImage? = {
  let side = 2 * (ribbonProxyShadowPad + ribbonProxyShadowCorner) + 2, scale: CGFloat = 2
  guard let context = CGContext(data: nil, width: Int(side * scale), height: Int(side * scale),
    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  context.scaleBy(x: scale, y: scale)
  // The shape sits outside the canvas; only its shadow lands inside.
  let shape = CGRect(x: ribbonProxyShadowPad, y: ribbonProxyShadowPad,
    width: side - 2 * ribbonProxyShadowPad, height: side - 2 * ribbonProxyShadowPad)
  context.setShadow(offset: CGSize(width: 1_000 * scale, height: 0), blur: 28,
    color: CGColor(gray: 0, alpha: 0.45))
  context.addPath(CGPath(roundedRect: shape.offsetBy(dx: -1_000, dy: 0),
    cornerWidth: ribbonProxyShadowCorner, cornerHeight: ribbonProxyShadowCorner, transform: nil))
  context.setFillColor(CGColor(gray: 0, alpha: 1))
  context.fillPath()
  return context.makeImage()
}()
package let ribbonProxyShadowCenter: CGRect = {
  let side = 2 * (ribbonProxyShadowPad + ribbonProxyShadowCorner) + 2
  let edge = (ribbonProxyShadowPad + ribbonProxyShadowCorner) / side
  return CGRect(x: edge, y: edge, width: 2 / side, height: 2 / side)
}()

/// Commits and flushes now; a commit slow enough to cost the compositor a frame is logged.
/// One refresh of `display`, 1/60 s when the mode reports none (some built-in panels).
func ribbonProxyFrameInterval(_ display: CGDirectDisplayID) -> CFTimeInterval {
  let rate = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
  return 1 / (rate > 0 ? rate : 60)
}

func ribbonProxyCommit(_ line: Int) {
  let start = CACurrentMediaTime()
  CATransaction.commit()
  CATransaction.flush()
  let ms = (CACurrentMediaTime() - start) * 1_000
  if ms > 2 { ribbonProxyLogger.notice("slow-commit line=\(line) ms=\(Int(ms))") }
}

package let ribbonProxyRadiusKey = "defiWindowRadius"

func ribbonProxySublayerFrames(_ layer: CALayer, size: CGSize,
  borderStyle: WindowBorderStyle?) -> [(CALayer, CGRect)] {
  (layer.sublayers ?? []).compactMap { sublayer in
    switch sublayer.name {
    case "content": return (sublayer, CGRect(origin: .zero, size: size))
    case "dim":
      sublayer.cornerRadius = layer.value(forKey: ribbonProxyRadiusKey) as? Double ?? 12
      return (sublayer, CGRect(origin: .zero, size: size))
    // The shadow falls 6 pt below the window, like the system's.
    case "shadow":
      let pad = ribbonProxyShadowPad
      return (sublayer, CGRect(x: -pad, y: -pad - 6, width: size.width + 2 * pad, height: size.height + 2 * pad))
    case "icon":
      return (sublayer, CGRect(x: size.width / 2 - 32, y: size.height / 2 - 32, width: 64, height: 64))
    case "border":
      guard let borderStyle else { return nil }
      // The native ring exactly: outside, it starts at the window edge and keeps its curve.
      let radius = layer.value(forKey: ribbonProxyRadiusKey) as? Double ?? 12
      let outset = borderStyle.placement == .outside ? sublayer.borderWidth : 0
      sublayer.cornerRadius = radius + outset
      return (sublayer, CGRect(x: -outset, y: -outset, width: size.width + 2 * outset,
        height: size.height + 2 * outset))
    default: return nil
    }
  }
}

struct RibbonProxyStretch {
  let id: WindowID
  let layer: CALayer
  let area: Rect
  /// The held window's frame when the gesture started, and every other ribbon window's.
  let base: Rect
  /// The window's own width bounds: the app refuses to go past them.
  let widths: ClosedRange<Double>
  let ribbon: [(CALayer, Rect)]
  let borderStyle: WindowBorderStyle?
  /// Fixed at the first event: the pointer's start, the native frame then, which edge moves.
  var anchor: (pointerX: Double, frame: Rect, movesLeft: Bool)?
}

/// The ribbon following a scroll gesture: each layer's resting centre, shifted by the
/// travel. Past `bounds` the shift meets the rubber band.
struct RibbonProxyPan {
  let id: UInt64
  let area: Rect
  let ribbon: [(CALayer, CGPoint)]
  /// Down the workspace stack instead of along the strip; shifts are in global
  /// coordinates (y grows downward).
  let vertical: Bool
  /// Where the ribbon is drawn when the gesture starts, from rest.
  let start: Double
  let scale: Double
  let bounds: ClosedRange<Double>
  let dimension: Double
  let stiffness: Double

  func shift(travel: Double) -> Double {
    rubberBanded(start + travel * scale, bounds: bounds, dimension: dimension, stiffness: stiffness)
  }
}

/// The resting bounds widened to where the overlay drew the strip, so a gesture starting
/// mid-motion does not jump into the rubber band.
public func ribbonPanBounds(_ bounds: ClosedRange<Double>, start: Double) -> ClosedRange<Double> {
  min(bounds.lowerBound, start)...max(bounds.upperBound, start)
}

/// Follows the pointer on the main thread at every display refresh. Mouse events
/// were not enough: while the WindowServer drags a window by its title bar they
/// arrive irregularly, and the proxy jumped between them.
final class RibbonProxyPointerTrack: @unchecked Sendable {
  enum Mode {
    /// The carried proxy keeps the native window's offset from the pointer.
    case carry(id: WindowID, layer: CALayer, area: Rect, grab: CGPoint?)
    /// The held edge follows the pointer; the ribbon shifts with it.
    case stretch(RibbonProxyStretch)
    /// The ribbon follows a scroll gesture's travel.
    case pan(RibbonProxyPan)
  }

  package static let shared = RibbonProxyPointerTrack()
  private let lock = NSLock()
  private var mode: Mode?
  /// Copies of the carried window on the other displays previewing its drop.
  private var guests: [(layer: CALayer, area: Rect)] = []
  /// The running scroll gesture's travel, written from the input thread.
  private var panTravel: (id: UInt64, travel: Double)?

  func setPanTravel(_ travel: (id: UInt64, travel: Double)?) { lock.withLock { panTravel = travel } }

  func set(_ mode: Mode?) {
    lock.withLock { self.mode = mode; if mode == nil { guests = [] } }
    let area: Rect? = switch mode {
    case .carry(_, _, let area, _): area
    case .stretch(let stretch): stretch.area
    case .pan(let pan): pan.area
    case nil: nil
    }
    DispatchQueue.main.async { MainActor.assumeIsolated { RibbonProxyPointerTicker.shared.run(on: area) } }
  }

  var isStretching: Bool { lock.withLock { if case .stretch = mode { true } else { false } } }

  func addGuest(_ layer: CALayer, area: Rect) { lock.withLock { guests.append((layer, area)) } }
  func removeGuest(_ layer: CALayer?) { lock.withLock { guests.removeAll { $0.layer === layer } } }

  /// `point` is in global top-left coordinates.
  func move(to point: CGPoint) {
    guard let (current, guests, panTravel) = lock.withLock({ self.mode.map { ($0, self.guests, self.panTravel) } })
    else { return }
    var mode = current
    CATransaction.begin(); CATransaction.setDisableActions(true)
    switch mode {
    case .carry(let id, let layer, let area, let grab):
      let local = ribbonProxyLocal(point, in: area)
      // Read with the pointer, at the same instant: the window kept moving since the
      // drag was detected, and an older position left the proxy trailing the cursor.
      let offset = grab ?? ribbonProxyNativeFrames([id])[id].map { native in
        let frame = ribbonProxyLocal(native, in: area)
        return CGPoint(x: frame.midX - local.x, y: frame.midY - local.y)
      } ?? CGPoint(x: layer.position.x - local.x, y: layer.position.y - local.y)
      layer.removePositionAnimations()
      var position = CGPoint(x: local.x + offset.x, y: local.y + offset.y)
      // Like the native window it stands for, the proxy stops at the menu bar: under it,
      // the menu bar shows the wallpaper and hid the window's top.
      if let visibleTop = RibbonProxyStore.shared.screen(containing: area)?.visibleFrame.y {
        position.y = min(position.y, area.y + area.height - visibleTop - layer.bounds.height / 2)
      }
      layer.position = position
      for guest in guests {
        let there = ribbonProxyLocal(point, in: guest.area)
        guest.layer.removePositionAnimations()
        guest.layer.position = CGPoint(x: there.x + offset.x, y: there.y + offset.y)
      }
      mode = .carry(id: id, layer: layer, area: area, grab: offset)
    case .stretch(var stretch):
      if stretch.anchor == nil, let start = ribbonProxyNativeFrames([stretch.id])[stretch.id] {
        // The pointer is on the held edge; a fast drag may already have resized the native frame.
        stretch.anchor = (Double(point.x), start, Double(point.x) < start.x + start.width / 2)
      }
      if let anchor = stretch.anchor {
        let delta = point.x - anchor.pointerX
        let width = min(max(anchor.frame.width + (anchor.movesLeft ? -delta : delta),
          stretch.widths.lowerBound), stretch.widths.upperBound)
        let held = Rect(x: anchor.movesLeft ? anchor.frame.x + anchor.frame.width - width : anchor.frame.x,
          y: anchor.frame.y, width: width, height: anchor.frame.height)
        let frame = ribbonProxyLocal(held, in: stretch.area)
        stretch.layer.removeAllAnimations()
        stretch.layer.frame = frame
        for (sublayer, subframe) in ribbonProxySublayerFrames(stretch.layer, size: frame.size,
          borderStyle: stretch.borderStyle) {
          sublayer.removeAllAnimations(); sublayer.frame = subframe
        }
        let left = held.x - stretch.base.x
        let right = held.x + held.width - stretch.base.x - stretch.base.width
        for (layer, base) in stretch.ribbon {
          let shift = base.x >= stretch.base.x + stretch.base.width - 1 ? right
            : base.x + base.width <= stretch.base.x + 1 ? left : 0
          let moved = ribbonProxyLocal(Rect(x: base.x + shift, y: base.y, width: base.width, height: base.height),
            in: stretch.area)
          layer.removePositionAnimations()
          layer.position = CGPoint(x: moved.midX, y: moved.midY)
        }
      }
      mode = .stretch(stretch)
    case .pan(let pan):
      let shift = pan.shift(travel: panTravel.flatMap { $0.id == pan.id ? $0.travel : nil } ?? 0)
      for (layer, rest) in pan.ribbon {
        layer.removePositionAnimations()
        layer.position = pan.vertical ? CGPoint(x: rest.x, y: rest.y - shift) : CGPoint(x: rest.x + shift, y: rest.y)
      }
    }
    ribbonProxyCommit(#line)
    let updated = mode
    lock.withLock { if self.mode != nil { self.mode = updated } }
  }
}


/// A CGImage carrying the capture's colour space: an untagged IOSurface is read as
/// sRGB and Display P3 windows looked washed out next to the real ones.
func ribbonProxyTaggedImage(_ buffer: CVPixelBuffer) -> CGImage? {
  var image: CGImage?
  VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
  return image
}

/// Reads the cursor once per frame while a window is held.
@MainActor
final class RibbonProxyPointerTicker: NSObject {
  package static let shared = RibbonProxyPointerTicker()
  private var link: CADisplayLink?
  private var area: Rect?

  /// Ticks at the refresh of the display holding the window, none without one.
  func run(on area: Rect?) {
    guard area != self.area else { return }
    link?.invalidate(); link = nil
    self.area = area
    guard let area, let screen = NSScreen.screens.first(where: { cgRect($0.frame) == area })
      ?? NSScreen.screens.first else { return }
    let link = screen.displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  @objc private func tick() {
    let location = NSEvent.mouseLocation
    let top = NSScreen.screens.first?.frame.height ?? 0
    RibbonProxyPointerTrack.shared.move(to: CGPoint(x: location.x, y: top - location.y))
  }
}
