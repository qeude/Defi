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


struct RibbonProxyWindow {
  let id: WindowID
  let appID: String
  let processID: Int32
  let from: Rect
  let to: Rect
  /// Just opened: it grows in its slot while its app draws it there under the overlay.
  var appears = false
  /// Drawn by Defi (a native fullscreen placeholder): never captured, no native window to land.
  var picture: CGImage? = nil
  /// In a pinned column: drawn above the strip scrolling beneath it.
  var pinned = false
  /// A scratchpad sliding in or out: above the strip, as its native windows are.
  var floats = false
}

/// Pictures stay valid only for the native size they were captured at.
package func ribbonProxyPictureMatches(captured: CGSize, native: Rect) -> Bool {
  abs(captured.width - native.width) < 3 && abs(captured.height - native.height) < 3
}

/// Beyond this age the app may have redrawn: the picture no longer shows its window.
let ribbonProxyPictureFreshness: TimeInterval = 1.5
/// A display's wallpaper capture older than this is retaken while the user is active.
let ribbonProxyBackgroundMaxAge: TimeInterval = 15

/// A held screen shows pictures in place of live windows that do not move: only a
/// sharp picture at the window's size looks the same. An old one is recaptured at once.
func ribbonProxyPictureShowsWindow(captured: CGSize, reduced: Bool, native: Rect) -> Bool {
  !reduced && ribbonProxyPictureMatches(captured: captured, native: native)
}

/// The overlay may lift once every visible native window sits on its target.
func ribbonProxyLanded(native: [WindowID: Rect], targets: [WindowID: Rect]) -> Bool {
  targets.allSatisfy { id, target in
    // Closed: nothing left to land, and its picture must not linger.
    guard let frame = native[id] else { return true }
    // Apps may snap their vertical extent (Ghostty sits 4 px lower on its cell grid);
    // the horizontal placement is what the ribbon controls exactly.
    return abs(frame.x - target.x) < 3 && abs(frame.width - target.width) < 3
      && abs(frame.y - target.y) < 12 && abs(frame.height - target.height) < 12
  }
}

/// The native targets a landing waits for. A target showing at most a sliver (an
/// offscreen column's anchor) is out of view like a leaving window, and macOS may keep
/// it a title bar higher than asked.
func ribbonProxyLandingTargets(_ targets: [WindowID: Rect], area: Rect) -> [WindowID: Rect] {
  targets.filter { windowProxyVisibleOverlap($0.value, area) > 2 }
}

/// A window leaving view, landing at most a sliver like the targets a landing skips: the
/// overlay waits until it is gone.
func ribbonProxyLeaves(from: Rect, to: Rect, area: Rect) -> Bool {
  from.ribbonIntersects(area) && windowProxyVisibleOverlap(to, area) <= 2
}

/// How an app adjusted a window Defi asked for at a target of `size` (its own clamp,
/// cell grid or minimum size): learned at each landing.
struct RibbonProxySettle: Sendable, Equatable {
  let size: CGSize
  let delta: Rect

  /// The adjustment, if small, between where a window was asked to go and where it went.
  init?(target: Rect, native: Rect) {
    let delta = Rect(x: native.x - target.x, y: native.y - target.y,
      width: native.width - target.width, height: native.height - target.height)
    guard [delta.x, delta.y, delta.width, delta.height].allSatisfy({ abs($0) < 40 }),
      [delta.x, delta.y, delta.width, delta.height].contains(where: { abs($0) >= 0.5 }) else { return nil }
    size = CGSize(width: target.width, height: target.height)
    self.delta = delta
  }

  /// A reflow rounding a column a point narrower keeps the app's placement.
  func matches(_ target: Rect) -> Bool {
    abs(target.width - size.width) < 3 && abs(target.height - size.height) < 3
  }

  /// Position always shifts; the size change only applies to the learned size.
  func apply(to frame: Rect) -> Rect {
    let sized = matches(frame)
    return Rect(x: frame.x + delta.x, y: frame.y + delta.y,
      width: frame.width + (sized ? delta.width : 0), height: frame.height + (sized ? delta.height : 0))
  }
}

/// Whether a layer frame shows more than a sliver: parked windows keep a 1-point strip
/// at the screen edge, which must not count as being on screen.
func ribbonProxyShows(_ frame: CGRect, in bounds: CGRect) -> Bool {
  let visible = frame.intersection(bounds)
  return visible.width > 4 && visible.height > 4
}

func ribbonProxyDistance(_ frame: Rect, _ area: Rect) -> Double {
  let gap = max(area.x - frame.x - frame.width, frame.x - area.x - area.width, 0)
  guard gap == 0 else { return gap }
  // A parked window's sliver, or a window above or below, is not in view: as far as another
  // workspace's. Counted in view, every landing recaptured it and the cap reduced it again.
  let visibleHeight = min(frame.y + frame.height, area.y + area.height) - max(frame.y, area.y)
  let visibleWidth = min(frame.x + frame.width, area.x + area.width) - max(frame.x, area.x)
  if visibleHeight <= 4 { return 100_000 }
  // Touching the edge without entering: the next column.
  if visibleWidth <= 0 { return 1 }
  return visibleWidth <= 4 ? 100_000 : 0
}


package struct RibbonProxyScreen: Sendable {
  package let displayID: CGDirectDisplayID
  // Top-left global coordinates, matching Accessibility and CGWindowList.
  package let frame: Rect
  package let visibleFrame: Rect
  package let scale: Double

  /// The overlay's surface: the whole screen below the menu bar. No window goes under the
  /// menu bar, and a surface there turned the transparent menu bar opaque.
  package var overlayArea: Rect {
    let top = max(visibleFrame.y, frame.y)
    return Rect(x: frame.x, y: top, width: frame.width, height: frame.y + frame.height - top)
  }

  package init(displayID: CGDirectDisplayID, frame: Rect, visibleFrame: Rect, scale: Double) {
    self.displayID = displayID
    self.frame = frame
    self.visibleFrame = visibleFrame
    self.scale = scale
  }
}

package struct RibbonProxyRefresh: Sendable {
  package let id: WindowID
  package let appID: String
  package let processID: Int32
  package let frame: Rect
  // Distance from the viewport along the ribbon; 0 means visible.
  package let distance: Double

  package init(id: WindowID, appID: String, processID: Int32, frame: Rect, distance: Double) {
    self.id = id
    self.appID = appID
    self.processID = processID
    self.frame = frame
    self.distance = distance
  }
}

/// Screen and motion state shared between the main thread and the navigation
/// presenter, so a navigation never waits for the main thread.
final package class RibbonProxyStore: @unchecked Sendable {
  package static let shared = RibbonProxyStore()
  private let lock = NSLock()
  private var screens: [RibbonProxyScreen] = []
  private var authorized = false
  private var reducesMotion = false
  private var motionTokens: [CGDirectDisplayID: UInt64] = [:]
  /// The presentation currently on each display; older landing checks stop reporting.
  func currentMotion(_ display: CGDirectDisplayID) -> UInt64 { locked { motionTokens[display] ?? 0 } }
  func setCurrentMotion(_ token: UInt64, _ display: CGDirectDisplayID) { locked { motionTokens[display] = token } }
  var reduceMotion: Bool {
    get { locked { reducesMotion } }
    set { locked { reducesMotion = newValue } }
  }
  private var springConfig = AnimationConfig()
  /// The configured overlay spring, read by every proxy motion.
  var spring: AnimationConfig {
    get { locked { springConfig } }
    set { locked { springConfig = newValue } }
  }
  private var movingDisplays: Set<CGDirectDisplayID> = []
  private var zoomingOverviews: Set<MonitorID> = []
  private var onScreenCache: [RibbonProxyOnScreenWindow] = []
  private var settles: [WindowID: RibbonProxySettle] = [:]
  var settled: [WindowID: RibbonProxySettle] { locked { settles } }
  func learnSettles(targets: [WindowID: Rect], native: [WindowID: Rect]) {
    locked {
      for (id, target) in targets {
        guard let frame = native[id] else { continue }
        settles[id] = RibbonProxySettle(target: target, native: frame)
      }
    }
  }
  /// The WindowServer list can stall for tens of milliseconds while it is busy, so
  /// navigation reads the last one, refreshed after each landing and every second.
  var onScreen: [RibbonProxyOnScreenWindow] {
    get { locked { onScreenCache } }
    set { locked { onScreenCache = newValue } }
  }
  /// Captures load the WindowServer, which also composites the motion: none run while
  /// any display moves.
  var isMoving: Bool { locked { !movingDisplays.isEmpty || !zoomingOverviews.isEmpty } }
  func setMoving(_ moving: Bool, _ display: CGDirectDisplayID) {
    locked { if moving { movingDisplays.insert(display) } else { movingDisplays.remove(display) } }
  }
  /// The Overview's opening zoom is a motion too, kept apart so neither clears the other.
  package func setOverviewZooming(_ zooming: Bool, _ monitorID: MonitorID) {
    locked { if zooming { zoomingOverviews.insert(monitorID) } else { zoomingOverviews.remove(monitorID) } }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    return body()
  }

  func screen(containing area: Rect) -> RibbonProxyScreen? {
    let x = area.x + area.width / 2, y = area.y + area.height / 2
    return locked {
      screens.first {
        x >= $0.frame.x && x < $0.frame.x + $0.frame.width
          && y >= $0.frame.y && y < $0.frame.y + $0.frame.height
      }
    }
  }
  var isAuthorized: Bool { locked { authorized } }
  var allScreens: [RibbonProxyScreen] { locked { screens } }
  func update(screens: [RibbonProxyScreen], authorized: Bool) {
    let ids = Set(screens.map(\.displayID))
    locked {
      self.screens = screens; self.authorized = authorized
      movingDisplays.formIntersection(ids)
    }
    WindowCaptureStore.shared.retainBackgrounds(ids)
    WindowCaptureStore.shared.fit(screens)
  }
}

struct RibbonProxyLayers: @unchecked Sendable {
  let root: CALayer
  let backdrop: CALayer
  let area: Rect
}
