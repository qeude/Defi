import AppKit
import AVFoundation
import DefiCore
import DefiModel
import QuartzCore

// Opt-in surface presentation only. Native geometry and focus remain owned by
// the regular frame coordinator; this scene never writes to user windows.
@MainActor
final class ExperimentalRibbonRenderer {
  static let shared = ExperimentalRibbonRenderer()
  private struct Context {
    let monitorID: MonitorID
    let workspaceID: WorkspaceID
    let frames: [WindowID: Rect]
    let owners: [WindowID: Int32]
    let screen: NSScreen
    let viewport: Rect
  }
  private var contexts: [Context] = []
  private var backgrounds: [MonitorID: CGImage] = [:]
  private var backgroundTask: Task<Void, Never>?
  private var scenes: [NSPanel] = []
  private var presentedLayers: [WindowID: (CALayer, Rect)] = [:]
  var isPresenting: Bool { !scenes.isEmpty }
  var backgroundsReady: Bool { contexts.allSatisfy { backgrounds[$0.monitorID] != nil } }
  private var retainedFrames: [WindowID: OverviewSurfaceFrame] = [:]
  private var completion: Task<Void, Never>?
  private var expectedNativeTargets: [WindowID: Rect] = [:]
  private var generation: UInt64 = 0
  private(set) var requests: [OverviewSurfaceRequest] = []
  private(set) var transitions = 0
  private(set) var fallbacks = 0
  private(set) var lastFallback = "none"

  func backgroundImage(for monitorID: MonitorID) -> CGImage? { backgrounds[monitorID] }

  func disable() {
    cancel(); contexts = []; requests = []; backgrounds = [:]
    backgroundTask?.cancel(); backgroundTask = nil
  }

  func capturedIDs(on monitorID: MonitorID) -> Set<WindowID> {
    Set(requests.map(\.windowID)).intersection(contexts.first {
      $0.monitorID == monitorID
    }?.frames.keys.map { $0 } ?? [])
  }

  func prepare(snapshot: OverviewSnapshot, layout: LayoutSettings, enabled: Bool) {
    guard enabled else {
      disable()
      return
    }
    var next: [Context] = []
    var candidates: [(request: OverviewSurfaceRequest, distance: Double)] = []
    for monitor in snapshot.monitors {
      guard let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint64Value == monitor.id.rawValue
      }), let viewport = snapshot.monitorFrames[monitor.id],
        let workspace = monitor.workspaces.first(where: { $0.id == monitor.activeWorkspace }),
        workspace.floatingWindows.isEmpty,
        Set(workspace.columns.flatMap(\.windows)).isDisjoint(with: snapshot.nativeFullscreenWindowIDs)
      else { continue }
      let frames = Dictionary(uniqueKeysWithValues: computeLayout(workspace: workspace,
        viewport: viewport, windows: Array(snapshot.windows.values), settings: layout)
        .map { ($0.windowID, $0.frame) })
      let owners = snapshot.windows.compactMapValues(\.processID)
      next.append(Context(monitorID: monitor.id, workspaceID: workspace.id,
        frames: frames, owners: owners, screen: screen, viewport: viewport))
      let visible = frames.filter { $0.value.ribbonIntersects(viewport) }
      let offscreen = frames.filter { !visible.keys.contains($0.key) }
      let ordered = offscreen.sorted {
        let left = distance($0.value, viewport), right = distance($1.value, viewport)
        return left == right ? $0.key.rawValue < $1.key.rawValue : left < right
      }
      let neighbours = [ordered.first(where: { $0.value.x + $0.value.width <= viewport.x }),
        ordered.first(where: { $0.value.x >= viewport.x + viewport.width })].compactMap { $0 }
      for (id, frame) in Array(visible) + Array(neighbours) {
        guard let window = snapshot.windows[id], let owner = owners[id],
          frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0
        else { continue }
        // Keep visible windows and immediate neighbours sharp; NV12 reduces the
        // capture pool without reducing luma resolution.
        let scale = screen.backingScaleFactor
        let width = frame.width * scale, height = frame.height * scale
        guard width <= 16_384, height <= 16_384 else { continue }
        candidates.append((OverviewSurfaceRequest(windowID: id, appID: window.appID,
          processID: owner, width: max((Int(width.rounded(.up)) + 1) / 2 * 2, 2),
          height: max((Int(height.rounded(.up)) + 1) / 2 * 2, 2)), visible[id] == nil ? distance(frame, viewport) + 1 : 0))
      }
    }
    contexts = next
    let required = candidates.filter { $0.distance == 0 }.map(\.request)
    var selected = required
    for item in candidates.filter({ $0.distance > 0 }).sorted(by: { $0.distance < $1.distance }) {
      if overviewSurfaceRequestsFit(selected + [item.request]) { selected.append(item.request) }
    }
    requests = selected.sorted { $0.windowID.rawValue < $1.windowID.rawValue }
    let ids = Set(next.map(\.monitorID))
    backgrounds = backgrounds.filter { id, image in
      guard ids.contains(id), let context = next.first(where: { $0.monitorID == id }) else { return false }
      return image.width == Int(context.screen.frame.width) && image.height == Int(context.screen.frame.height)
    }
    guard backgroundTask == nil, next.contains(where: { backgrounds[$0.monitorID] == nil }) else { return }
    let desktopRequests = next.filter { backgrounds[$0.monitorID] == nil }.map {
      OverviewDesktopCaptureRequest(monitorID: $0.monitorID,
        displayID: UInt32($0.monitorID.rawValue), width: Int($0.screen.frame.width),
        height: Int($0.screen.frame.height))
    }
    backgroundTask = Task { [weak self] in
      let result = await captureOverviewImages(previews: [], desktops: desktopRequests, previewCompleted: { _ in })
      guard !Task.isCancelled, let self else { return }
      backgrounds.merge(result.desktops) { _, new in new }
      backgroundTask = nil
    }
  }

  // Runs synchronously on the main actor before the native submission starts.
  // False leaves the original native animation fully functional.
  func begin(assignments: [FrameAssignment], duration: TimeInterval,
    borderStyle: WindowBorderStyle? = nil, selectedWindowID: WindowID? = nil) -> Bool {
    let previousPresentation = presentedLayers.mapValues { entry -> CGRect in
      (entry.0.presentation()?.frame ?? entry.0.frame).offsetBy(dx: entry.1.x, dy: entry.1.y)
    }
    cancel()
    guard duration > 0, !contexts.isEmpty,
      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { lastFallback = "disabled-or-no-context"; return false }
    let targets = Dictionary(uniqueKeysWithValues: assignments.map { ($0.windowID, $0.frame) })
    var plans: [(Context, Double, Set<WindowID>)] = []
    for context in contexts {
      let viewport = context.viewport
      guard let destination = targets.first(where: {
        context.frames[$0.key] != nil && $0.value.ribbonOverlapWidth(viewport) > 2
      }), let source = context.frames[destination.key] else { continue }
      let delta = destination.value.x - source.x
      guard abs(delta) > 0.5 else { continue }
      let ids = Set(context.frames.filter {
        $0.value.ribbonIntersects(viewport) || shifted($0.value, delta).ribbonIntersects(viewport)
      }.keys)
      guard backgrounds[context.monitorID] != nil,
        ids.allSatisfy({ id in
          guard let frame = context.frames[id], let target = targets[id] else { return false }
          return abs(frame.width - target.width) < 1 && abs(frame.height - target.height) < 1
        }), OverviewSurfaceCapture.shared.frames(windowIDs: ids) != nil,
        ids.allSatisfy({ OverviewSurfaceCapture.shared.displayLayer(for: $0) != nil })
      else { lastFallback = "capture-or-background-or-size"; fallbacks += 1; return false }
      plans.append((context, delta, ids))
    }
    guard !plans.isEmpty else { lastFallback = "no-moving-plan"; return false }
    let native = nativeFrames()
    for (context, _, ids) in plans {
      for id in ids {
        guard let actual = native[id], actual.owner == context.owners[id],
          let source = context.frames[id],
          !source.ribbonIntersects(screenRect(context.screen)) || matches(actual.frame, source)
        else { lastFallback = "native-source-mismatch id=\(id.rawValue) actual=\(String(describing: native[id]?.frame)) source=\(String(describing: context.frames[id]))"; fallbacks += 1; return false }
      }
    }
    var expected: [WindowID: (Rect, Int32)] = [:]
    for (context, delta, ids) in plans {
      guard let frames = OverviewSurfaceCapture.shared.frames(windowIDs: ids) else { cancel(); return false }
      retainedFrames.merge(frames) { _, new in new }
      let area = context.viewport
      let appKitArea = CGRect(x: area.x, y: (NSScreen.screens.first?.frame.height ?? 0) - area.y - area.height,
        width: area.width, height: area.height)
      let panel = NSPanel(contentRect: appKitArea,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false
      panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
      panel.isReleasedWhenClosed = false; panel.level = .statusBar
      panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
      panel.setAccessibilityLabel("Defi experimental ribbon")
      let view = NSView(frame: CGRect(origin: .zero, size: appKitArea.size))
      view.wantsLayer = true
      let root = CALayer(); root.frame = view.bounds; root.isGeometryFlipped = true
      root.masksToBounds = true; view.layer = root; panel.contentView = view
      let backdrop = CALayer(); backdrop.frame = root.bounds
      let screenOrigin = screenRect(context.screen)
      backdrop.contents = backgrounds[context.monitorID]?.cropping(to: CGRect(
        x: area.x - screenOrigin.x, y: area.y - screenOrigin.y, width: area.width, height: area.height))
      root.addSublayer(backdrop)
      let origin = context.viewport
      for id in ids {
        guard let frame = context.frames[id], let pixels = frames[id] else { continue }
        guard let item = OverviewSurfaceCapture.shared.displayLayer(for: id) else { cancel(); return false }
        item.removeFromSuperlayer(); item.removeAllAnimations()
        item.transform = CATransform3DIdentity
        item.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        _ = enqueueWindowSurface(pixels, on: item)
        item.contentsGravity = .resize
        item.frame = previousPresentation[id]?.offsetBy(dx: -origin.x, dy: -origin.y)
          ?? CGRect(x: frame.x - origin.x, y: frame.y - origin.y,
            width: frame.width, height: frame.height)
        let container = CALayer(); container.frame = item.frame
        item.frame = container.bounds
        item.cornerRadius = 9; item.masksToBounds = true; container.addSublayer(item)
        if let borderStyle, let appearance = overviewWindowBorderAppearance(
          isSelected: id == selectedWindowID, style: borderStyle, scale: 1) {
          let geometry = overviewWindowBorderGeometry(
            cardFrame: Rect(x: 0, y: 0, width: frame.width, height: frame.height),
            cardRadius: 9, width: appearance.width, placement: borderStyle.placement)
          let border = CAShapeLayer()
          border.path = CGPath(roundedRect: CGRect(x: geometry.frame.x, y: geometry.frame.y,
            width: geometry.frame.width, height: geometry.frame.height),
            cornerWidth: geometry.radius, cornerHeight: geometry.radius, transform: nil)
          let color = appearance.color
          border.strokeColor = NSColor(srgbRed: CGFloat((color >> 16) & 255) / 255,
            green: CGFloat((color >> 8) & 255) / 255, blue: CGFloat(color & 255) / 255,
            alpha: CGFloat(windowBorderAlpha(of: color)) / 255).cgColor
          border.fillColor = nil; border.lineWidth = appearance.width
          container.addSublayer(border)
        }
        root.addSublayer(container)
        let start = container.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        container.position = CGPoint(x: frame.x - origin.x + delta + frame.width / 2,
          y: frame.y - origin.y + frame.height / 2)
        CATransaction.commit()
        presentedLayers[id] = (container, origin)
        let motion = CABasicAnimation(keyPath: "position")
        motion.fromValue = NSValue(point: start); motion.toValue = NSValue(point: container.position)
        motion.duration = duration; motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(motion, forKey: "ribbon")
        if let target = targets[id], let owner = context.owners[id] {
          expected[id] = (target, owner)
        }
      }
      panel.orderFrontRegardless(); scenes.append(panel)
    }
    CATransaction.flush()
    expectedNativeTargets = expected.mapValues { $0.0 }
    transitions += 1
    let token = generation
    completion = Task { [weak self] in
      let animationEnd = CACurrentMediaTime() + duration
      while !Task.isCancelled, let self, generation == token, CACurrentMediaTime() < animationEnd {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (id, entry) in presentedLayers {
          if let frame = OverviewSurfaceCapture.shared.frames(windowIDs: [id])?[id],
            frame.surface !== retainedFrames[id]?.surface {
            if let video = entry.0.sublayers?.first as? AVSampleBufferDisplayLayer { _ = enqueueWindowSurface(frame, on: video) }; retainedFrames[id] = frame
          }
        }
        CATransaction.commit()
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      }
      let deadline = CACurrentMediaTime() + 1
      while !Task.isCancelled, let self, generation == token {
        let current = nativeFrames()
        if expected.allSatisfy({ id, value in
          current[id].map { $0.owner == value.1 && matches($0.frame, value.0) } ?? false
        }) { cancel(); return }
        if CACurrentMediaTime() > deadline { fallbacks += 1; cancel(); return }
        do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
      }
    }
    return true
  }

  func supersedeIfTargetsChanged(_ assignments: [FrameAssignment]) {
    guard isPresenting else { return }
    if assignments.contains(where: { assignment in
      expectedNativeTargets[assignment.windowID].map { !matches($0, assignment.frame) } ?? false
    }) { cancel() }
  }

  func cancel() {
    generation &+= 1; completion?.cancel(); completion = nil
    for panel in scenes { panel.orderOut(nil); panel.close() }
    scenes = []; retainedFrames = [:]; presentedLayers = [:]; expectedNativeTargets = [:]
  }

  private func distance(_ a: Rect, _ b: Rect) -> Double {
    max(b.x - a.x - a.width, a.x - b.x - b.width, 0)
  }
  private func shifted(_ frame: Rect, _ dx: Double) -> Rect {
    Rect(x: frame.x + dx, y: frame.y, width: frame.width, height: frame.height)
  }
  private func screenRect(_ screen: NSScreen) -> Rect {
    Rect(x: screen.frame.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.frame.maxY,
      width: screen.frame.width, height: screen.frame.height)
  }
  private func matches(_ a: Rect, _ b: Rect) -> Bool {
    abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
  }
  private func nativeFrames() -> [WindowID: (frame: Rect, owner: Int32)] {
    var result: [WindowID: (Rect, Int32)] = [:]
    for info in CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? [] {
      guard let number = info[kCGWindowNumber as String] as? NSNumber,
        let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
      result[WindowID(rawValue: number.uint64Value)] = (Rect(x: frame.minX, y: frame.minY,
        width: frame.width, height: frame.height), owner.int32Value)
    }
    return result
  }
}

private extension Rect {
  func ribbonOverlapWidth(_ other: Rect) -> Double {
    max(min(x + width, other.x + other.width) - max(x, other.x), 0)
  }
  func ribbonIntersects(_ other: Rect) -> Bool {
    x + width > other.x && other.x + other.width > x
      && y + height > other.y && other.y + other.height > y
  }
}
