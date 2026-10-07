import DefiRuntime
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Synchronization
import ScreenCaptureKit
import XCTest
import class SwiftUI.NSHostingMenu
import class SwiftUI.NSHostingView

@testable import DefiMacOS

private final class DesktopHotKeyObserver: Sendable {
  let repeats = Mutex<[Bool]>([])
}

@MainActor
final class DesktopE2ETests: XCTestCase {
  func testOverviewKeyboardWorkspaceTransitionKeepsIntermediatePositions() async throws {
    _ = try makePlatform()
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      throw XCTSkip("Overview animation requires Reduce Motion to be disabled")
    }
    let screen = try XCTUnwrap(NSScreen.main)
    let monitorID = MonitorID(rawValue: (screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint64Value)
    let windows = (0..<5).map { index in
      Window(id: WindowID(rawValue: UInt64(index + 1)), appID: "test", title: "Vertical window \(index)",
        frame: Rect(x: 0, y: 0, width: 700, height: 700), processID: getpid())
    }
    let workspaces = windows.map { window in
      Workspace(id: WorkspaceID(rawValue: "vertical-\(window.id.rawValue)"),
        columns: [Column(window: window.id, width: .fraction(0.5))])
    }
    func snapshot(_ active: Int) -> OverviewSnapshot {
      OverviewSnapshot(monitors: [Monitor(id: monitorID, workspaces: workspaces,
        activeWorkspace: workspaces[active].id)], monitorFrames: [monitorID:
          Rect(x: 0, y: 0, width: screen.frame.width, height: screen.visibleFrame.height)],
        windows: Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) }), activeMonitorID: monitorID)
    }
    var nativeSelections: [WindowID] = []
    let controller = OverviewController(focusWindow: { id, _, _, _ in nativeSelections.append(id) },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    controller.open(snapshot: snapshot(2), layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close(); controller.close() }
    func findView(_ view: NSView) -> OverviewView? {
      if let overview = view as? OverviewView { return overview }
      return view.subviews.compactMap(findView).first
    }
    let input = try XCTUnwrap(NSApp.windows.compactMap { $0.contentView.flatMap(findView) }.first)
    func frame() throws -> CGRect {
      let children = try XCTUnwrap(input.accessibilityChildren() as? [NSAccessibilityElement])
      return try XCTUnwrap(children.first { $0.accessibilityLabel() == "Vertical window 2" }).accessibilityFrame()
    }
    try await Task.sleep(for: .milliseconds(250))
    let before = try frame()
    controller.handleKey(.down)
    try await Task.sleep(for: .milliseconds(45))
    let awaitingActivation = try frame()
    XCTAssertTrue(nativeSelections.isEmpty, "Overview arrows must not move native windows")
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    XCTAssertEqual(try frame().minY, awaitingActivation.minY, accuracy: 1,
      "An unchanged runtime snapshot must preserve deferred navigation")
    XCTAssertGreaterThan(abs(awaitingActivation.minY - before.minY), 1,
      "Vertical keyboard navigation must animate before native activation completes")
    controller.update(snapshot: snapshot(3), layout: LayoutSettings())
    XCTAssertEqual(try frame().minY, awaitingActivation.minY, accuracy: 1,
      "Activating the workspace must preserve the displayed source position")
    try await Task.sleep(for: .milliseconds(35))
    let intermediate = try frame()
    XCTAssertGreaterThan(abs(intermediate.minY - awaitingActivation.minY), 1,
      "Activation must preserve the ongoing animation timeline")
    controller.handleKey(.up)
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    XCTAssertEqual(try frame().minY, intermediate.minY, accuracy: 1,
      "Repeated arrows must resume from the displayed position")
    for _ in 0..<10 {
      try await Task.sleep(for: .milliseconds(20))
      controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    }
    XCTAssertEqual(try frame().minY, before.minY, accuracy: 1,
      "Snapshot refreshes must not prevent the transition from finishing")
    controller.handleKey(.down)
    controller.handleKey(.up)
    controller.update(snapshot: snapshot(2), layout: LayoutSettings())
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(try frame().minY, before.minY, accuracy: 1,
      "A reversal before the first refresh must cancel the superseded destination")
    controller.handleKey(.down)
    try await Task.sleep(for: .milliseconds(35))
    controller.update(snapshot: snapshot(1), layout: LayoutSettings())
    try await Task.sleep(for: .milliseconds(200))
    let actualTarget = projectOverview(snapshot: snapshot(1), monitorID: monitorID,
      bounds: Rect(x: 0, y: 0, width: input.bounds.width, height: input.bounds.height),
      viewport: OverviewViewport(), layout: LayoutSettings(), zoom: 0.5)
    let expectedCard = try XCTUnwrap(actualTarget.workspaces.flatMap(\.windows).first {
      $0.windowID == windows[2].id
    }).frame
    let expectedFrame = try XCTUnwrap(input.window).convertToScreen(input.convert(
      NSRect(x: expectedCard.x, y: expectedCard.y, width: expectedCard.width, height: expectedCard.height), to: nil))
    XCTAssertEqual(try frame().minY, expectedFrame.minY, accuracy: 1,
      "An unrelated workspace activation must supersede the predicted destination")
  }

  func testOverviewNavigationRenderBudget() async throws {
    _ = try makePlatform()
    let screen = try XCTUnwrap(NSScreen.main)
    let monitorID = MonitorID(rawValue: (screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint64Value)
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    let panel = OverviewPanel(monitorID: monitorID, screen: screen,
      usesCapturedDesktop: true, delegate: controller)
    defer { panel.hide() }
    var windows: [WindowID: Window] = [:]
    let workspaces = (0..<5).map { row in
      Workspace(id: WorkspaceID(rawValue: "render-\(row)"), columns: (0..<4).map { column in
        let id = WindowID(rawValue: UInt64(row * 4 + column + 1))
        windows[id] = Window(id: id, appID: "com.apple.finder", title: "Overview render fixture \(id)",
          frame: Rect(x: 0, y: 0, width: 1200, height: 1300), processID: getpid())
        return Column(window: id, width: .fraction(0.66))
      })
    }
    let snapshot = OverviewSnapshot(monitors: [Monitor(id: monitorID, workspaces: workspaces,
      activeWorkspace: workspaces[2].id)], monitorFrames: [monitorID:
        Rect(x: 0, y: 0, width: screen.frame.width, height: screen.visibleFrame.height)],
      windows: windows, activeMonitorID: monitorID)
    let image = NSImage(size: NSSize(width: 1024, height: 1024))
    image.lockFocus()
    NSGradient(starting: .systemBlue, ending: .systemOrange)!.draw(in:
      NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 45)
    image.unlockFocus()
    let previews = windows.mapValues { _ in image }
    panel.setDesktopImage(image)
    panel.show()
    var costs: [Double] = []
    for index in 0..<160 {
      let projection = projectOverview(snapshot: snapshot, monitorID: monitorID,
        bounds: Rect(x: 0, y: 0, width: panel.view.bounds.width, height: panel.view.bounds.height),
        viewport: OverviewViewport(workspaceOffset: sin(Double(index) / 20) * 0.6),
        layout: LayoutSettings(), zoom: 0.5)
      let started = CACurrentMediaTime()
      panel.view.update(snapshot: snapshot, projection: projection, selection: nil, drag: nil,
        borderStyle: WindowBorderStyle(config: BordersConfig()), windowCornerRadius: 12,
        previews: previews, previewOpacities: [:])
      panel.view.displayIfNeeded()
      if index >= 20 { costs.append(CACurrentMediaTime() - started) }
      if index % 20 == 0 { await Task.yield() }
    }
    let sorted = costs.sorted()
    let mean = costs.reduce(0, +) / Double(costs.count)
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    print("DEFI_E2E overview-draw meanMs=\(mean * 1000) p95Ms=\(p95 * 1000) samples=\(costs.count)")
    XCTAssertLessThan(p95, 1 / Double(max(screen.maximumFramesPerSecond, 60)),
      "Warm overview drawing must fit one refresh budget")
    XCTAssertLessThanOrEqual(panel.view.titleRasterizationCount, windows.count,
      "Moving cards must reuse their rendered titles")

    // The same view is a real event source for the controller's installed panel.
    controller.open(snapshot: snapshot, layout: LayoutSettings(), windowPreviewsEnabled: false)
    defer { controller.close() }
    func findView(_ view: NSView) -> OverviewView? {
      if let overview = view as? OverviewView { return overview }
      return view.subviews.compactMap(findView).first
    }
    let input = try XCTUnwrap(NSApp.windows.compactMap { window -> OverviewView? in
      guard window !== panel.window, let root = window.contentView else { return nil }
      return findView(root)
    }.first)
    let groups = try XCTUnwrap(input.accessibilityChildren() as? [NSAccessibilityElement])
    let group = try XCTUnwrap(groups.first { $0.accessibilityRole() == .group })
    let label = group.accessibilityLabel()
    let before = group.accessibilityFrame()
    let updatesBeforeScroll = input.presentationUpdateCount
    for _ in 0..<100 {
      controller.overviewView(input, scrolled: NSPoint(x: 0, y: -1),
        hasPreciseScrollingDeltas: true, at: NSPoint(x: 100, y: 100))
    }
    XCTAssertLessThan(input.presentationUpdateCount - updatesBeforeScroll, 5,
      "Precise events must coalesce rather than project every input event")
    try await Task.sleep(for: .milliseconds(100))
    let afterGroups = try XCTUnwrap(input.accessibilityChildren() as? [NSAccessibilityElement])
    let after = try XCTUnwrap(afterGroups.first { $0.accessibilityLabel() == label }).accessibilityFrame()
    XCTAssertEqual(after.minY - before.minY, 100, accuracy: 0.5,
      "The last pending frame must preserve all trackpad deltas")
  }

  func testOverviewPressureRecoveryPreloadsAgainWithoutOpening() async throws {
    _ = try makePlatform()
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission unavailable to test process")
    }
    let screen = try XCTUnwrap(NSScreen.main)
    let fixture = NSWindow(contentRect: NSRect(x: screen.frame.midX - 320,
      y: screen.frame.midY - 220, width: 640, height: 440),
      styleMask: [.titled], backing: .buffered, defer: false)
    fixture.isReleasedWhenClosed = false
    fixture.orderFrontRegardless()
    defer { fixture.close() }
    let id = WindowID(rawValue: UInt64(fixture.windowNumber))
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let owner = try XCTUnwrap(content.windows.first(where: { $0.windowID == fixture.windowNumber })?.owningApplication)
    let monitor = MonitorID(rawValue: (screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint64Value)
    let workspace = Workspace(id: WorkspaceID(rawValue: "pressure-preview"),
      columns: [Column(window: id, width: .fraction(0.5))])
    let snapshot = OverviewSnapshot(monitors: [Monitor(id: monitor,
      workspaces: [workspace], activeWorkspace: workspace.id)],
      monitorFrames: [monitor: Rect(x: screen.frame.minX, y: 0,
        width: screen.frame.width, height: 440)],
      windows: [id: Window(id: id, appID: owner.bundleIdentifier, title: "Pressure preview",
        frame: Rect(x: 0, y: 0, width: 640, height: 440),
        processID: owner.processID)], activeMonitorID: monitor)
    let recoveries = DesktopValue<Int>(0)
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, idlePreparationRequested: { recoveries.value += 1 },
      notificationCenter: NotificationCenter(), commitScrollOffsets: { _ in })
    defer { controller.prepare(windowPreviewsEnabled: false) }
    func prepare() {
      controller.prepare(windowPreviewsEnabled: true, snapshot: snapshot,
        layout: LayoutSettings(), experimentalSurfaceTransitions: true)
    }
    prepare()
    for _ in 0..<80 where controller.rememberedPreviewMemoryBytes == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    let bytes = controller.rememberedPreviewMemoryBytes
    XCTAssertGreaterThan(bytes, 0)
    controller.handleMemoryPressure(.warning)
    XCTAssertEqual(controller.rememberedPreviewMemoryBytes, bytes)
    XCTAssertLessThanOrEqual(bytes, 4 * 1_024 * 1_024)
    controller.handleMemoryPressure(.critical)
    XCTAssertEqual(controller.rememberedPreviewMemoryBytes, 0)
    controller.handleMemoryPressure(.normal)
    XCTAssertEqual(recoveries.value, 1)
    prepare()
    for _ in 0..<80 where controller.rememberedPreviewMemoryBytes == 0 {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertGreaterThan(controller.rememberedPreviewMemoryBytes, 0,
      "The same preview request must run again after eviction, without an overview opening")
    XCTAssertFalse(controller.isOpen)
  }

  func testOverviewAvailableSurfacesRetainReadyImageWhenAnotherIsMissing() async throws {
    _ = try makePlatform()
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission unavailable to test process")
    }
    let fixture = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 440),
      styleMask: [.titled], backing: .buffered, defer: false)
    fixture.isReleasedWhenClosed = false
    fixture.orderFrontRegardless()
    fixture.displayIfNeeded()
    CATransaction.flush()
    let capture = OverviewSurfaceCapture.shared
    defer { capture.stop(); fixture.close() }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let native = try XCTUnwrap(content.windows.first { $0.windowID == fixture.windowNumber })
    let owner = try XCTUnwrap(native.owningApplication)
    let id = WindowID(rawValue: UInt64(native.windowID))
    capture.prepare([OverviewSurfaceRequest(windowID: id,
      appID: owner.bundleIdentifier, processID: owner.processID, width: 640, height: 440)], enabled: true)
    for _ in 0..<60 where capture.displayLayer(for: id) == nil {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertNotNil(capture.displayLayer(for: id))
    let missing = WindowID(rawValue: UInt64.max)
    XCTAssertNil(capture.frames(windowIDs: [id, missing]),
      "Native ribbon replacement must remain all-or-nothing")
    let available = try XCTUnwrap(capture.availableFrames(windowIDs: [id, missing]))
    XCTAssertEqual(Set(available.keys), [id],
      "A missing image must not cancel the ready overview texture")
    XCTAssertNil(capture.availableFrames(windowIDs: [missing]))
    let screen = try XCTUnwrap(fixture.screen)
    let monitorID = MonitorID(rawValue: (screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint64Value)
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let frame = Rect(x: fixture.frame.minX, y: primaryHeight - fixture.frame.maxY,
      width: fixture.frame.width, height: fixture.frame.height)
    let workspace = Workspace(id: WorkspaceID(rawValue: "opening-fallback"),
      columns: [Column(window: id, width: .fraction(0.5))])
    let snapshot = OverviewSnapshot(monitors: [Monitor(id: monitorID,
      workspaces: [workspace], activeWorkspace: workspace.id)],
      monitorFrames: [monitorID: Rect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
        width: screen.frame.width, height: screen.frame.height)],
      windows: [id: Window(id: id, appID: owner.bundleIdentifier, title: "Opening fallback",
        frame: frame, processID: owner.processID)], activeMonitorID: monitorID)
    let projection = projectOverview(snapshot: snapshot, monitorID: monitorID,
      bounds: Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
      viewport: OverviewViewport(), layout: LayoutSettings(), zoom: 0.5)
    let cached = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      NSColor.red.setFill(); rect.fill(); return true
    }
    for previews: [WindowID: NSImage] in [[:], [id: cached]] {
      let scene = try XCTUnwrap(OverviewSurfaceScene(projection: projection,
        workspaceID: workspace.id, screen: screen, surfaces: [:],
        windows: snapshot.windows, previews: previews))
      XCTAssertEqual(Set(scene.nativeFrames.keys), [id])
      let item = try XCTUnwrap(scene.layer.sublayers?.first)
      XCTAssertEqual(item.contents != nil, !previews.isEmpty)
      if previews.isEmpty {
        XCTAssertGreaterThan(item.borderWidth, 0)
        XCTAssertNotNil(item.sublayers?.first?.contents,
          "An uncaptured window must remain recognizable during the zoom")
      } else {
        XCTAssertTrue(item.sublayers?.isEmpty ?? true)
      }
      // An unattached layer has no render-tree animation lifetime. Host the
      // scene as production does before checking its running animation.
      fixture.contentView?.wantsLayer = true
      fixture.contentView?.layer?.addSublayer(scene.layer)
      scene.animate(opening: true, duration: 0.22)
      XCTAssertNotNil(item.animation(forKey: "overview-surface"),
        "Opening must zoom even without a ready screenshot")
      XCTAssertEqual(scene.finishOpening(), [id])
      XCTAssertTrue(scene.nativeFrames.isEmpty, "Closing must not reuse opening fallback layers")
      XCTAssertTrue(scene.layer.sublayers?.isEmpty ?? true)
      scene.layer.removeFromSuperlayer()
    }
  }

  func testOverviewSurfaceTransitionUsesFreshOwnedWindowAndReopensSafely() async throws {
    _ = try makePlatform()
    guard CGPreflightScreenCaptureAccess() else {
      print("DEFI_E2E screen-recording=unavailable")
      throw XCTSkip("Screen Recording permission unavailable to test process")
    }
    print("DEFI_E2E screen-recording=available")
    let screen = try XCTUnwrap(NSScreen.main)
    let recordsEvidence = ProcessInfo.processInfo.environment["DEFI_SURFACE_DEMO"] == "1"
    var backdrop: NSWindow?
    if recordsEvidence {
      let background = NSWindow(contentRect: screen.frame, styleMask: .borderless,
        backing: .buffered, defer: false)
      background.isReleasedWhenClosed = false
      background.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
      background.orderFrontRegardless()
      backdrop = background
    }
    defer { backdrop?.close() }
    let fixture = NSWindow(contentRect: NSRect(x: screen.frame.midX - 320,
      y: screen.frame.midY - 220, width: 640, height: 440),
      styleMask: [.titled], backing: .buffered, defer: false)
    var nativeFrame = screen.visibleFrame
    nativeFrame.size.width = 640
    fixture.setFrame(nativeFrame, display: false)
    fixture.title = "Defi Surface Fixture"
    fixture.isReleasedWhenClosed = false
    fixture.animationBehavior = .none
    let contentView = NSView()
    contentView.wantsLayer = true
    contentView.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.24, alpha: 1).cgColor
    let title = NSTextField(labelWithString: "NATIVE WINDOW → LIVE OVERVIEW")
    title.font = NSFont.systemFont(ofSize: 23, weight: .semibold)
    title.textColor = .white
    let contentHeight = fixture.contentLayoutRect.height
    title.frame = NSRect(x: 32, y: contentHeight - 90, width: 580, height: 40)
    contentView.addSubview(title)
    let description = NSTextField(labelWithString: "Direct ScreenCaptureKit surface · no bitmap conversion")
    description.font = NSFont.systemFont(ofSize: 17)
    description.textColor = .lightGray
    description.frame = NSRect(x: 32, y: contentHeight - 132, width: 580, height: 30)
    contentView.addSubview(description)
    let dot = CALayer()
    dot.backgroundColor = NSColor.systemTeal.cgColor
    dot.frame = CGRect(x: 32, y: contentHeight / 2 - 36, width: 72, height: 72)
    dot.cornerRadius = 36
    contentView.layer?.addSublayer(dot)
    let movement = CABasicAnimation(keyPath: "position.x")
    movement.fromValue = 68
    movement.toValue = 560
    movement.duration = 1.2
    movement.autoreverses = true
    movement.repeatCount = .infinity
    dot.add(movement, forKey: "live-content")
    fixture.contentView = contentView
    fixture.orderFrontRegardless()
    fixture.displayIfNeeded()
    CATransaction.flush()
    defer { fixture.close() }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let native = try XCTUnwrap(content.windows.first(where: { $0.windowID == fixture.windowNumber }))
    let nativeFrameBounds = CGRect(x: fixture.frame.minX,
      y: (NSScreen.screens.first?.frame.height ?? 0) - fixture.frame.maxY,
      width: fixture.frame.width, height: fixture.frame.height)
    var fixtureIsSettled = false
    for _ in 0..<30 {
      let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow,
        CGWindowID(fixture.windowNumber)) as? [[String: Any]])?.first(where: {
          ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == fixture.windowNumber
        })
      if let bounds = info?[kCGWindowBounds as String] as? [String: Any],
        CGRect(dictionaryRepresentation: bounds as CFDictionary) == nativeFrameBounds {
        fixtureIsSettled = true; break
      }
      CATransaction.flush()
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(fixtureIsSettled, "Owned fixture must finish its native appearance before sampling")
    let appID = try XCTUnwrap(native.owningApplication?.bundleIdentifier)
    let processID = try XCTUnwrap(native.owningApplication?.processID)
    let windowID = WindowID(rawValue: UInt64(native.windowID))
    let monitorID = MonitorID(rawValue: (screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint64Value)
    let workspace = Workspace(id: WorkspaceID(rawValue: "surface-fixture"),
      columns: [Column(window: windowID, width: .fraction(nativeFrameBounds.width / screen.frame.width))])
    let snapshot = OverviewSnapshot(
      monitors: [Monitor(id: monitorID, workspaces: [workspace], activeWorkspace: workspace.id)],
      monitorFrames: [monitorID: Rect(x: screen.frame.minX, y: nativeFrameBounds.minY,
        width: screen.frame.width, height: nativeFrameBounds.height)],
      windows: [windowID: Window(id: windowID, appID: appID, title: fixture.title,
        frame: Rect(x: nativeFrameBounds.minX, y: nativeFrameBounds.minY,
          width: nativeFrameBounds.width, height: nativeFrameBounds.height), processID: processID)],
      activeMonitorID: monitorID)
    let surfaceLayout = LayoutSettings(outerTopGap: 0, outerRightGap: 0,
      outerBottomGap: 0, outerLeftGap: 0)
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in })
    defer {
      controller.close()
      controller.prepare(windowPreviewsEnabled: false)
    }
    controller.prepare(windowPreviewsEnabled: true, snapshot: snapshot, layout: surfaceLayout,
      experimentalSurfaceTransitions: true)
    for _ in 0..<60 where controller.surfaceCaptureState == "warming" {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(controller.surfaceCaptureState, "ready")
    try await Task.sleep(for: .milliseconds(150))
    let originalCapture = try XCTUnwrap(OverviewSurfaceCapture.shared.frames(windowIDs: [windowID])?[windowID])
    OverviewSurfaceCapture.shared.prepare([OverviewSurfaceRequest(windowID: windowID,
      appID: "different.owner", processID: processID + 1,
      width: originalCapture.width, height: originalCapture.height)], enabled: true)
    XCTAssertNil(OverviewSurfaceCapture.shared.frames(windowIDs: [windowID]),
      "A reused ID must stop exposing the previous owner's pixels immediately, including during throttle")
    controller.prepare(windowPreviewsEnabled: true, snapshot: snapshot, layout: surfaceLayout,
      experimentalSurfaceTransitions: true)
    for _ in 0..<80 where controller.surfaceCaptureState != "ready" {
      try await Task.sleep(for: .milliseconds(100))
    }
    let capturedFrames = try XCTUnwrap(OverviewSurfaceCapture.shared.frames(windowIDs: [windowID]))
    let projection = projectOverview(snapshot: snapshot, monitorID: monitorID,
      bounds: Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height),
      viewport: OverviewViewport(), layout: surfaceLayout, zoom: 0.5)
    let previousScene = try XCTUnwrap(OverviewSurfaceScene(projection: projection,
      workspaceID: workspace.id, screen: screen, surfaces: capturedFrames,
      windows: snapshot.windows))
    previousScene.animate(opening: true, duration: 0)
    let reusedLayer = try XCTUnwrap(OverviewSurfaceCapture.shared.displayLayer(for: windowID))
    XCTAssertFalse(CATransform3DIsIdentity(reusedLayer.transform))
    XCTAssertEqual(reusedLayer.cornerRadius * reusedLayer.transform.m11, 12, accuracy: 0.01,
      "The overview texture must match the card's radius after scaling")
    let reopenedScene = try XCTUnwrap(OverviewSurfaceScene(projection: projection,
      workspaceID: workspace.id, screen: screen, surfaces: capturedFrames,
      windows: snapshot.windows))
    XCTAssertTrue(CATransform3DIsIdentity(reusedLayer.transform),
      "A reused Overview texture must start at native scale, even after a non-reversing close")
    XCTAssertEqual(reusedLayer.cornerRadius, 12)
    XCTAssertEqual(reusedLayer.bounds.size, nativeFrameBounds.size)
    _ = reopenedScene
    // Isolate the owned-window handoff from unrelated user windows. The
    // production observer remains conservative whenever another window is visible.
    var visibleWindowInfo: [[String: Any]] = []
    let renderer = ExperimentalRibbonRenderer(visibleWindowInfo: { visibleWindowInfo })
    renderer.prepare(snapshot: snapshot, layout: surfaceLayout, enabled: true)
    defer { renderer.disable() }
    for _ in 0..<120 where !renderer.backgroundsReady {
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(renderer.backgroundsReady, "Owned renderer background capture must finish before animation")
    let originalRibbonFrame = fixture.frame
    let target = Rect(x: nativeFrameBounds.minX + 60, y: nativeFrameBounds.minY,
      width: nativeFrameBounds.width, height: nativeFrameBounds.height)
    XCTAssertTrue(renderer.begin(assignments: [FrameAssignment(windowID: windowID, frame: target)], duration: 0.15), renderer.lastFallback)
    XCTAssertTrue(renderer.isPresenting)
    let firstPanels = Set(NSApplication.shared.windows.filter {
      $0.title == "Defi Experimental Ribbon"
    }.map(\.windowNumber))
    XCTAssertEqual(firstPanels.count, 1)
    fixture.setFrame(originalRibbonFrame.offsetBy(dx: 60, dy: 0), display: true)
    let retarget = Rect(x: target.x + 30, y: target.y,
      width: target.width, height: target.height)
    XCTAssertTrue(renderer.begin(assignments: [FrameAssignment(windowID: windowID, frame: retarget)],
      duration: 0.15), renderer.lastFallback)
    XCTAssertEqual(Set(NSApplication.shared.windows.filter {
      $0.title == "Defi Experimental Ribbon"
    }.map(\.windowNumber)), firstPanels, "Retargeting must reuse the visible overlay without a close/reopen")
    fixture.setFrame(originalRibbonFrame.offsetBy(dx: 90, dy: 0), display: true)
    for _ in 0..<30 where renderer.isPresenting {
      CATransaction.flush()
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertFalse(renderer.isPresenting, "Proxy must yield after native convergence")
    fixture.setFrame(originalRibbonFrame, display: true)
    renderer.prepare(snapshot: snapshot, layout: surfaceLayout, enabled: true)
    CATransaction.flush()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(renderer.begin(assignments: [FrameAssignment(windowID: windowID, frame: target)], duration: 0.15))
    XCTAssertFalse(renderer.begin(assignments: [FrameAssignment(windowID: windowID,
      frame: target)], duration: 0.15))
    XCTAssertFalse(renderer.isPresenting, "A no-plan fallback must dismiss an older proxy")
    visibleWindowInfo = [[kCGWindowNumber as String: NSNumber(value: UInt64.max),
      kCGWindowOwnerPID as String: NSNumber(value: Int32.max),
      kCGWindowLayer as String: NSNumber(value: 0),
      kCGWindowBounds as String: nativeFrameBounds.dictionaryRepresentation]]
    XCTAssertFalse(renderer.begin(assignments: [FrameAssignment(windowID: windowID, frame: retarget)], duration: 0.15))
    XCTAssertEqual(renderer.lastFallback, "unrepresented-window")
    XCTAssertFalse(renderer.isPresenting, "Unrepresented windows must remain visible on the native path")
    visibleWindowInfo = []

    // AppKit may normalize a prepared panel's frame. Rebuilding it must keep captures warm.
    for panel in NSApplication.shared.windows where panel.title == "Defi Overview" {
      panel.setFrame(panel.frame.offsetBy(dx: 1, dy: 0), display: false)
    }
    if recordsEvidence {
      for _ in 0..<20 {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
      }
    }
    // A delayed idle refresh must not discard the last compatible snapshot.
    try await Task.sleep(for: .seconds(3.2))
    let originalFrame = fixture.frame
    for sample in 0..<2 {
      controller.open(snapshot: snapshot, layout: surfaceLayout, windowPreviewsEnabled: true,
        experimentalSurfaceTransitions: true)
      XCTAssertEqual(controller.surfaceTransitionCount, sample + 1)
      XCTAssertEqual(controller.surfaceFallbackCount, 0)
      XCTAssertEqual(controller.surfaceStreamCount, 0)
      XCTAssertLessThanOrEqual(controller.surfaceEstimatedPoolBytes, overviewSurfacePoolBudget)
      print("DEFI_E2E surface sample=\(sample) acquireMs=\(controller.surfaceAcquireMs) poolBytes=\(controller.surfaceEstimatedPoolBytes)")
      for _ in 0..<(recordsEvidence ? 40 : (sample == 0 ? 66 : 6)) {
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
      }
      XCTAssertEqual(controller.surfacePresentedFrameCount, 1,
        "The zoom must retain one fixed screenshot, without live swaps or capture sessions")
      XCTAssertEqual(fixture.frame, originalFrame, "Projection must not mutate native geometry")
      controller.close()
      // Discovery ticks during closing must not replace the texture being handed back.
      controller.prepare(windowPreviewsEnabled: true, snapshot: snapshot, layout: surfaceLayout,
        experimentalSurfaceTransitions: true)
      CATransaction.flush()
      if sample == 0 {
        // Reopen before the previous closing task ends; it must not hide the new scene.
        try await Task.sleep(for: .milliseconds(60))
      } else {
        try await Task.sleep(for: .milliseconds(300))
      }
    }
    // Enter on the current selection must reverse the zoom just like toggling.
    controller.open(snapshot: snapshot, layout: surfaceLayout, windowPreviewsEnabled: true,
      experimentalSurfaceTransitions: true)
    try await Task.sleep(for: .milliseconds(250))
    controller.handleKey(.select)
    try await Task.sleep(for: .milliseconds(180))
    XCTAssertFalse(controller.isOpen)
    XCTAssertEqual(controller.surfacePresentedFrameCount, 1,
      "Enter must retain the surface scene during the closing zoom")
    // Simulate resource expiry winning over a delayed closing continuation.
    controller.releaseIdleOverviewResources()
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.allSatisfy { !$0.isVisible },
      "Memory cleanup must hide the overlay even when it cancels the closing task")
    try await Task.sleep(for: .milliseconds(250))
    if recordsEvidence { try await Task.sleep(for: .seconds(1)) }
    XCTAssertFalse(controller.isOpen)
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.allSatisfy { !$0.isVisible })
    // Workspace navigation invalidates the original full-resolution scene. Its
    // already-displayed preview must still animate back to the target window.
    let destination = NSWindow(contentRect: originalFrame, styleMask: [.titled],
      backing: .buffered, defer: false)
    destination.isReleasedWhenClosed = false
    destination.title = "Defi Destination Fixture"
    destination.backgroundColor = .systemBlue
    destination.setFrame(originalFrame, display: true)
    destination.orderFrontRegardless()
    defer { destination.close() }
    let destinationID = WindowID(rawValue: UInt64(destination.windowNumber))
    let destinationWorkspace = Workspace(id: WorkspaceID(rawValue: "destination"),
      columns: [Column(window: destinationID, width: .fraction(nativeFrameBounds.width / screen.frame.width))])
    var destinationWindows = snapshot.windows
    destinationWindows[destinationID] = Window(id: destinationID, appID: appID,
      title: destination.title, frame: snapshot.windows[windowID]!.frame, processID: processID)
    func navigationSnapshot(active: WorkspaceID) -> OverviewSnapshot {
      OverviewSnapshot(monitors: [Monitor(id: monitorID,
        workspaces: [workspace, destinationWorkspace], activeWorkspace: active)],
        monitorFrames: snapshot.monitorFrames, windows: destinationWindows,
        activeMonitorID: monitorID)
    }
    controller.prepare(windowPreviewsEnabled: true, snapshot: navigationSnapshot(active: workspace.id),
      layout: surfaceLayout, experimentalSurfaceTransitions: true)
    controller.open(snapshot: navigationSnapshot(active: workspace.id), layout: surfaceLayout,
      windowPreviewsEnabled: true, experimentalSurfaceTransitions: true)
    controller.handleKey(.down)
    controller.update(snapshot: navigationSnapshot(active: destinationWorkspace.id),
      layout: surfaceLayout, windowPreviewsEnabled: true)
    for _ in 0..<30 where controller.previewCacheCount == 0 {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(250))
    controller.handleKey(.select)
    try await Task.sleep(for: .milliseconds(180))
    XCTAssertFalse(controller.isOpen)
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.contains { $0.isVisible },
      "Changing workspace must retain the displayed preview during the reverse zoom")
    XCTAssertEqual(controller.previewClosingCount, 1)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.allSatisfy { !$0.isVisible })
    XCTAssertEqual(destination.frame, originalFrame)
    controller.prepare(windowPreviewsEnabled: false)
    controller.open(snapshot: snapshot, layout: surfaceLayout, windowPreviewsEnabled: false)
    XCTAssertTrue(ExperimentalRibbonRenderer.shared.requests.isEmpty)
    controller.update(snapshot: snapshot, layout: surfaceLayout, windowPreviewsEnabled: false,
      experimentalSurfaceTransitions: false, experimentalRibbonRepresentations: true)
    XCTAssertTrue(ExperimentalRibbonRenderer.shared.requests.contains { $0.windowID == windowID },
      "Enabling representations in an open Overview must prepare the current native context")
    for _ in 0..<80 where controller.surfaceCaptureState != "ready" {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(controller.surfaceCaptureState, "ready")
    controller.update(snapshot: snapshot, layout: surfaceLayout,
      experimentalSurfaceTransitions: false, experimentalRibbonRepresentations: false)
    XCTAssertTrue(ExperimentalRibbonRenderer.shared.requests.isEmpty)
    controller.close()
    controller.prepare(windowPreviewsEnabled: false)
    XCTAssertEqual(controller.surfaceStreamCount, 0)
  }

  func testOverviewShowsBothMonitorsBeforeLoadingPreviews() throws {
    _ = try makePlatform()
    let screens = NSScreen.screens
    guard screens.count > 1 else { throw XCTSkip("Requires two connected displays") }
    var windows: [WindowID: Window] = [:]
    var frames: [MonitorID: Rect] = [:]
    let monitors = screens.enumerated().map { index, screen in
      let id = MonitorID(rawValue: (screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")
      ] as! NSNumber).uint64Value)
      frames[id] = Rect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
      let workspaces = (0..<4).map { row in
        let columns = (0..<6).map { column in
          let windowID = WindowID(rawValue: UInt64(1_000_000 + index * 100 + row * 6 + column))
          windows[windowID] = Window(
            id: windowID, appID: "test.overview", title: "Window \(column)",
            frame: Rect(x: 0, y: 0, width: 800, height: 600)
          )
          return Column(window: windowID, width: .fraction(0.5))
        }
        return Workspace(id: WorkspaceID(rawValue: "\(index)-\(row)"), columns: columns)
      }
      return Monitor(id: id, workspaces: workspaces, activeWorkspace: workspaces[0].id)
    }
    let controller = OverviewController(
      focusWindow: { _, _, _, _ in }, focusWorkspace: { _, _ in },
      drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in }
    )
    defer { controller.close() }
    controller.prepare(windowPreviewsEnabled: true)
    XCTAssertFalse(controller.isOpen)
    XCTAssertEqual(controller.retainedPanelCount, screens.count)
    XCTAssertTrue(NSApplication.shared.windows.filter { $0.title == "Defi Overview" }.allSatisfy { !$0.isVisible })
    for sample in 0..<3 {
      let start = ProcessInfo.processInfo.systemUptime
      controller.open(
        snapshot: OverviewSnapshot(monitors: monitors, monitorFrames: frames, windows: windows),
        layout: LayoutSettings(), windowPreviewsEnabled: true
      )
      let panels = NSApplication.shared.windows.filter { $0.title == "Defi Overview" && $0.isVisible }
      for panel in panels { panel.displayIfNeeded() }
      let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1_000
      print("DEFI_E2E overview-open sample=\(sample) monitors=\(screens.count) windows=\(windows.count) ms=\(elapsed)")
      XCTAssertEqual(panels.count, screens.count)
      XCTAssertTrue(panels.allSatisfy { $0.alphaValue == 1 }, "Overview must be visible before captures or a delayed fade")
      XCTAssertEqual(controller.previewCacheCount, 0)
      controller.handleKey(.cancel)
      XCTAssertFalse(controller.isOpen)
      XCTAssertTrue(panels.allSatisfy { !$0.isVisible })
    }
  }

  private func makePlatform() throws -> MacOSPlatform {
    guard ProcessInfo.processInfo.environment["DEFI_E2E"] == "1" else {
      throw XCTSkip("Set DEFI_E2E=1 to run real-desktop tests")
    }
    let platform = onNavigation { MacOSPlatform() }
    guard platform.accessibilityTrusted(prompt: false) else {
      print("DEFI_E2E accessibility=unavailable")
      throw XCTSkip("Accessibility permission unavailable to test process")
    }
    print("DEFI_E2E accessibility=available")
    return platform
  }

  private func testWindows(in snapshot: DesktopSnapshot) -> [Window] {
    let candidates = snapshot.windows
      .filter {
        $0.appID != "com.openai.codex"
          && $0.intrinsicSize == false
      }
    let visibleCandidates = candidates.filter { window in
      snapshot.monitors.contains { monitor in
        let windowRight = window.frame.x + window.frame.width
        let monitorRight = monitor.frame.x + monitor.frame.width
        let intersectionWidth = max(
          min(windowRight, monitorRight) - max(window.frame.x, monitor.frame.x),
          0
        )
        let windowBottom = window.frame.y + window.frame.height
        let monitorBottom = monitor.frame.y + monitor.frame.height
        let intersectionHeight = max(
          min(windowBottom, monitorBottom) - max(window.frame.y, monitor.frame.y),
          0
        )
        return intersectionWidth > 2 && intersectionHeight > 2
      }
    }
    return (visibleCandidates.isEmpty ? candidates : visibleCandidates)
      .sorted {
        if $0.appID == "com.t3tools.t3code" {
          return $1.appID != "com.t3tools.t3code"
        }
        if $1.appID == "com.t3tools.t3code" {
          return false
        }
        return $0.id.rawValue < $1.id.rawValue
      }
  }

  func testFocusedWindowRemainsResolvableWhileParkedOffscreen() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(x: -10_000, y: -10_000, width: original.width, height: original.height)
      )
    ]) }
    pumpRunLoop(for: 0.2)
    onNavigation { platform.focus(window.id) }
    pumpRunLoop(for: 0.5)

    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testKeyboardActivationAfterCompletedFocusSurvivesSnapshot() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    let originalApplication = NSWorkspace.shared.frontmostApplication
    guard let window = testWindows(in: initial).first(where: {
      $0.processID != originalApplication?.processIdentifier
    }), let processID = window.processID else {
      throw XCTSkip("A window in another application is required")
    }
    defer { originalApplication?.activate() }

    let result = DesktopValue<NativeFocusResult?>(nil)
    onNavigation { platform.focus(window.id, completion: { value in DispatchQueue.main.async { result.value = value } }) }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while result.value == nil && ProcessInfo.processInfo.systemUptime < deadline {
      pumpRunLoop(for: 0.01)
    }
    XCTAssertEqual(result.value, .completed)
    let suppression = try XCTUnwrap(platform.internalFocusSuppressions[window.id])
    XCTAssertNotNil(suppression.completedAt)

    // Inject the normalized keyboard/activation events; resolve the target via real AX.
    let inputTimestamp = ProcessInfo.processInfo.systemUptime
    platform.userInputTracker.record(timestamp: inputTimestamp, focusIntent: .keyboard)
    platform.userInputTracker.recordApplicationActivation(processID: processID)
    let snapshot = platform.snapshot(config: Config())
    XCTAssertEqual(snapshot.focusedWindowID, window.id)
    XCTAssertTrue(snapshot.nativeFocusChanged)
    XCTAssertTrue(snapshot.nativeFocusIsApplicationActivation)
    XCTAssertNil(platform.internalFocusSuppressions[window.id])
  }

  func testFailedApplicationConnectionIsRenewedWithoutRestart() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    guard let window = testWindows(in: initial).first,
      let processID = window.processID
    else { throw XCTSkip("No manageable desktop application") }

    // Simulate a cached connection that cannot serve the application's windows.
    platform.snapshotEngine.applications[processID] = AXUIElementCreateApplication(-1)
    platform.requestWindowTopologyRefresh(processID: processID)
    _ = platform.snapshot(config: Config())
    let renewed = try XCTUnwrap(platform.snapshotEngine.applications[processID])
    var renewedProcessID: pid_t = 0
    XCTAssertEqual(AXUIElementGetPid(renewed, &renewedProcessID), .success)
    XCTAssertEqual(renewedProcessID, processID)

    platform.requestWindowTopologyRefresh(processID: processID)
    let recovered = platform.snapshot(config: Config())
    XCTAssertTrue(recovered.windows.contains { $0.id == window.id })
  }

  func testObsoleteWindowDoesNotDisableSiblingObservation() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let processID = window.processID,
      let element = platform.elements[window.id]
    else { throw XCTSkip("No manageable desktop application") }
    let monitor = PlatformEventMonitor(handler: { _, _ in })
    defer { monitor.stop() }
    let obsolete = AXUIElementCreateApplication(-1)
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [processID: [obsolete]])
    }
    XCTAssertEqual(
      monitor.notificationObservationFailureCountsValue[.windowTopology]?[processID],
      notificationObservationMaxAttempts
    )
    monitor.refresh(applications: [processID: [obsolete, element]])
    XCTAssertEqual(monitor.observationCoverage.topologyWindows, 1)
    XCTAssertEqual(monitor.observationCoverage.frameWindows, 1)
  }

  func testWindowObservationRecoversAfterTemporaryRegistrationFailure() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let processID = window.processID,
      let element = platform.elements[window.id]
    else { throw XCTSkip("No manageable desktop window") }
    var time: TimeInterval = 0
    var frameEvents = 0
    let monitor = PlatformEventMonitor(
      handler: { kind, _ in if kind == .frame { frameEvents += 1 } },
      now: { time },
      addNotification: { observer, element, notification, context in
        if time < 30, notification as String == kAXMovedNotification {
          return .cannotComplete
        }
        return AXObserverAddNotification(observer, element, notification, context)
      }
    )
    defer {
      monitor.stop()
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    for _ in 0..<notificationObservationMaxAttempts {
      monitor.refresh(applications: [processID: [element]])
    }
    XCTAssertFalse(monitor.hasReliableFrameCoverage())
    time = 30
    monitor.refresh(applications: [processID: [element]])
    XCTAssertTrue(monitor.hasReliableFrameCoverage())
    XCTAssertTrue(monitor.notificationObservationFailureCountsValue.isEmpty)
    var moved = window.frame
    moved.x += 8
    moved.width -= 16
    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: moved)]) }
    XCTAssertTrue(pumpRunLoop(until: { frameEvents > 0 }, timeout: 1),
                  "Recovered observer did not receive native frame notifications")
  }

  func testTiledFocusKeepsFloatingWindowAboveIt() throws {
    let platform = try makePlatform()
    let initial = platform.snapshot(config: Config())
    let onscreenWindowIDs = Set(
      copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    // Use a regular native window with a local floating rule. AppKit About
    // panels can hide on deactivation and are not a cross-app stacking fixture.
    guard let candidate = testWindows(in: initial).first(where: { window in
      onscreenWindowIDs.contains(window.id) && initial.monitors.contains { monitor in
        targetIntersects(window.frame, monitor: monitor.frame)
          && initial.windows.contains { other in
            other.processID != window.processID && !other.floating
              && onscreenWindowIDs.contains(other.id)
              && targetIntersects(other.frame, monitor: monitor.frame)
          }
      }
    }) else { throw XCTSkip("Two on-screen applications on one monitor required") }
    let config = Config(rules: [Rule(appID: candidate.appID, floating: true)])
    let snapshot = platform.snapshot(config: config)
    guard let floating = snapshot.windows.first(where: {
      $0.id == candidate.id && $0.floating && onscreenWindowIDs.contains($0.id)
    }),
      let monitor = snapshot.monitors.first(where: {
        $0.frame.x < floating.frame.x + floating.frame.width
          && floating.frame.x < $0.frame.x + $0.frame.width
          && $0.frame.y < floating.frame.y + floating.frame.height
          && floating.frame.y < $0.frame.y + $0.frame.height
      }),
      let tiled = snapshot.windows.first(where: {
        !$0.floating
          && $0.processID != floating.processID
          && onscreenWindowIDs.contains($0.id)
          && monitor.frame.x < $0.frame.x + $0.frame.width
          && $0.frame.x < monitor.frame.x + monitor.frame.width
          && monitor.frame.y < $0.frame.y + $0.frame.height
          && $0.frame.y < monitor.frame.y + monitor.frame.height
      })
    else {
      throw XCTSkip("On-screen floating and tiled windows from different apps required")
    }
    let originalFocusedWindowID = snapshot.focusedWindowID
    defer {
      if let originalFocusedWindowID {
        onNavigation { platform.focus(originalFocusedWindowID) }
        pumpRunLoop(for: 0.3)
      }
    }

    let focusResult = DesktopValue<NativeFocusResult?>(nil)
    onNavigation { platform.focus(floating.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult.value == .completed || focusResult.value == .completedWithoutMutation)
    guard let tiledElement = platform.elements[tiled.id],
      let processID = tiled.processID,
      let tiledApplication = platform.applications[processID]
    else {
      XCTFail("Tiled test window lost its Accessibility elements")
      return
    }
    focusResult.value = nil
    onNavigation { platform.focus(tiled.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertEqual(
      AXUIElementPerformAction(
        tiledElement,
        kAXRaiseAction as CFString
      ),
      .success
    )
    pumpRunLoop(for: 0.1)
    _ = platform.snapshot(config: config)

    focusResult.value = nil
    onNavigation { platform.focus(tiled.id, completion: { value in DispatchQueue.main.async { focusResult.value = value } }) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { focusResult.value != nil },
        timeout: 1
      )
    )
    XCTAssertTrue(focusResult.value == .completed || focusResult.value == .completedWithoutMutation)

    // AX success acknowledges the request before WindowServer necessarily
    // publishes the new order. Assert native convergence, not callback timing.
    let expectedForegroundIDs = snapshot.windows.filter { window in
      window.floating && onscreenWindowIDs.contains(window.id)
        && monitor.frame.x < window.frame.x + window.frame.width
        && window.frame.x < monitor.frame.x + monitor.frame.width
        && monitor.frame.y < window.frame.y + window.frame.height
        && window.frame.y < monitor.frame.y + monitor.frame.height
    }.map(\.id).sorted { $0.rawValue < $1.rawValue }
    let relevantWindowIDs = Set(expectedForegroundIDs + [floating.id, tiled.id])
    var observedRelevantOrder: [String] = []
    let floatingRemainedAboveTiled = pumpRunLoop(until: {
      let records = copyCGWindows(options: [.optionOnScreenOnly, .excludeDesktopElements])
      let relevantRecords = records.filter {
        relevantWindowIDs.contains(WindowID(rawValue: UInt64($0.id)))
      }
      observedRelevantOrder = relevantRecords.map {
        "\($0.id)/pid=\($0.processID)/\($0.ownerName)/layer=\($0.layer)"
      }
      let order = records.map { WindowID(rawValue: UInt64($0.id)) }
      guard let floatingIndex = order.firstIndex(of: floating.id),
        let tiledIndex = order.firstIndex(of: tiled.id) else { return false }
      return floatingIndex < tiledIndex
    }, timeout: 0.5)
    let focusPerformance = platform.focusWriter.performance
    let cachedWindowClassification = platform.lastSnapshotWindows
      .filter { relevantWindowIDs.contains($0.id) }
      .map {
        "\($0.id.rawValue)/pid=\($0.processID ?? -1)/floating=\($0.floating)/frame=\($0.frame)"
      }
    let floatingIDs = platform.floatingWindowIDs.sorted { $0.rawValue < $1.rawValue }
    let hiddenIDs = platform.lastHiddenWindowIDs.sorted { $0.rawValue < $1.rawValue }
    XCTAssertTrue(
      floatingRemainedAboveTiled,
      "fixture candidate=\(candidate.id.rawValue); floating \(floating.id.rawValue)/pid=\(floating.processID ?? -1) must remain above tiled \(tiled.id.rawValue)/pid=\(tiled.processID ?? -1); expected foreground float IDs=\(expectedForegroundIDs.map(\.rawValue)); cached floating IDs=\(floatingIDs.map(\.rawValue)), hidden IDs=\(hiddenIDs.map(\.rawValue)), relevant cached windows=\(cachedWindowClassification); focus timing ms duration/raise/activation=\(focusPerformance.durationMS)/\(focusPerformance.raiseDurationMS)/\(focusPerformance.activationDurationMS); observed front-to-back relevant CG windows=\(observedRelevantOrder)"
    )
    var focusedWindow: CFTypeRef?
    XCTAssertEqual(
      AXUIElementCopyAttributeValue(
        tiledApplication,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindow
      ),
      .success
    )
    XCTAssertTrue(focusedWindow.map { CFEqual($0, tiledElement) } == true)
  }

  func testAppliedTargetConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let candidates = testWindows(in: snapshot).filter {
      $0.frame.width > 500
    }
    guard candidates.isEmpty == false else {
      throw XCTSkip("No resizable desktop window")
    }
    var failures: [String] = []
    for window in candidates {
      let original = window.frame
      let target = Rect(
        x: original.x + 40,
        y: original.y,
        width: original.width - 80,
        height: original.height
      )
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: target)]) }
      let converged = pumpRunLoop(
        until: {
          let actual = platform.snapshot(config: Config()).windows
            .first(where: { $0.id == window.id })?.frame
          return abs((actual?.x ?? .infinity) - target.x) <= 2
            && abs((actual?.width ?? .infinity) - target.width) <= 2
        },
        timeout: 0.8
      )
      let actual = platform.snapshot(config: Config()).windows
        .first(where: { $0.id == window.id })?.frame
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
      if converged {
        return
      }
      failures.append(
        "\(window.appID)#\(window.id.rawValue) target=\(target) actual=\(String(describing: actual))"
      )
    }
    XCTFail("No resizable AX window converged: \(failures.joined(separator: "; "))")
  }

  func testUserAdjustedFramesReadFreshGeometryOffNavigationExecutor() async throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    onNavigation {
      platform.latestObservedFrames[window.id] = Rect(x: -20_000, y: -20_000, width: 1, height: 1)
    }
    let frames = await platform.userAdjustedFrames(for: [window.id])
    let actual = try XCTUnwrap(frames[window.id])
    XCTAssertEqual(actual.x, window.frame.x, accuracy: 2)
    XCTAssertEqual(actual.y, window.frame.y, accuracy: 2)
    XCTAssertEqual(actual.width, window.frame.width, accuracy: 2)
    XCTAssertEqual(actual.height, window.frame.height, accuracy: 2)
  }

  func testHorizontalAnimationFrameWritesPositionWithoutSize() throws {
    try verifyHorizontalFrameWritesPositionWithoutSize(animationDuration: 0.15)
  }

  func testDisabledHorizontalAnimationWritesOnlyTheFinalPosition() throws {
    try verifyHorizontalFrameWritesPositionWithoutSize(animationDuration: 0)
  }

  private func verifyHorizontalFrameWritesPositionWithoutSize(animationDuration: Double) throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 1))
    let positionWrites = onNavigation { platform.successfulPositionWriteCount }
    let sizeWrites = onNavigation { platform.successfulSizeWriteCount }

    onNavigation { platform.apply([
      FrameAssignment(
        windowID: window.id,
        frame: Rect(
          x: original.x + 8,
          y: original.y,
          width: original.width,
          height: original.height
        )
      )
    ], animationDuration: animationDuration, animationRefreshRateHz: 120,
       animationDisplayIDs: Set(snapshot.monitors.map { $0.id.rawValue })) }
    XCTAssertTrue(pumpRunLoop(until: {
      !onNavigation { platform.hasPendingFrameWrites }
    }, timeout: 2))
    let frames = onNavigation { platform.frameCoordinatorPerformance.animationFrames }
    if animationDuration > 0 { XCTAssertGreaterThan(frames, 1) }
    else { XCTAssertEqual(frames, 1) }

    XCTAssertGreaterThan(onNavigation { platform.successfulPositionWriteCount }, positionWrites)
    XCTAssertEqual(onNavigation { platform.successfulSizeWriteCount }, sizeWrites)
  }

  func testManagedResizeAnimationConvergesWithAdaptiveSizeWrites() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first else {
      throw XCTSkip("No desktop monitor")
    }
    guard let window = testWindows(in: snapshot).first(where: {
      $0.frame.width >= 500
        && $0.frame.x < monitor.frame.x + monitor.frame.width
        && $0.frame.x + $0.frame.width > monitor.frame.x
    }) else {
      throw XCTSkip("No visible resizable desktop window")
    }
    let original = window.frame
    let target = Rect(
      x: original.x,
      y: original.y,
      width: original.width - 120,
      height: original.height
    )
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 1))
    let sizeWrites = onNavigation { platform.successfulSizeWriteCount }
    // A recent stall must adapt the width animation instead of discarding it.
    if let processID = window.processID {
      platform.frameCoordinator.recordProcessLatencySamples([processID: 70])
    }

    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      animationDuration: 0.08,
      animationRefreshRateHz: 120,
      animateSizeChanges: true,
      source: "command-layout-animation"
    ) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 1
      )
    )

    var actual: Rect?
    let converged = pumpRunLoop(
      until: {
        actual = platform.snapshot(config: Config()).windows
          .first(where: { $0.id == window.id })?.frame
        return abs((actual?.width ?? .infinity) - target.width) <= 2
      },
      timeout: 1
    )
    XCTAssertTrue(
      converged,
      "resize animation did not converge; app=\(window.appID) target=\(target) actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })"
    )
    XCTAssertEqual(actual?.width ?? 0, target.width, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      onNavigation { platform.successfulSizeWriteCount } - sizeWrites,
      3,
      "A resize animation must write intermediate sizes, not only its final size."
    )
  }

  func testAnimatedFullWidthConvergesFromBothViewportEdges() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let monitor = try XCTUnwrap(snapshot.monitors.first)
    let window = try XCTUnwrap(testWindows(in: snapshot).first(where: {
      $0.appID == "com.mitchellh.ghostty"
    }) ?? testWindows(in: snapshot).first)
    let original = window.frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    let full = Rect(x: monitor.frame.x, y: original.y,
      width: monitor.frame.width, height: original.height)
    for fraction in [0.5, 0.0, 0.25] {
      let start = Rect(x: monitor.frame.x + monitor.frame.width * fraction, y: original.y,
        width: monitor.frame.width / 2, height: original.height)
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: start)]) }
      XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 2))
      // Refresh the observed starting frame before the animated enlargement.
      _ = platform.snapshot(config: Config())
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: full)],
        animationDuration: 0.125, animationRefreshRateHz: 120,
        animateSizeChanges: true, source: "command-layout-animation") }
      XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 2))
      var actual: Rect?
      let converged = pumpRunLoop(until: {
        actual = platform.snapshot(config: Config()).windows.first { $0.id == window.id }?.frame
        guard let actual else { return false }
        return abs(actual.x - full.x) <= 2 && abs(actual.width - full.width) <= 2
      }, timeout: 1)
      XCTAssertTrue(converged,
        "Full width from \(fraction) must converge; actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })")
    }
  }

  func testUnhiddenOnePixelStripAnchorConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let candidates = testWindows(in: snapshot).filter {
      !$0.intrinsicSize && $0.frame.width >= 300
    }
    let preferredWindow =
      candidates.first(where: { $0.appID == "com.t3tools.t3code" })
      ?? candidates.max(by: { $0.frame.width < $1.frame.width })
    guard let window = preferredWindow,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let original = window.frame
    let staged = Rect(
      x: monitor.frame.x
        + max(monitor.frame.width - original.width, 0) / 2,
      y: monitor.frame.y
        + max(monitor.frame.height - original.height, 0) / 2,
      width: original.width,
      height: original.height
    )
    let anchored = resolveParkingPlacement(
      for: staged,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      onNavigation { platform.apply(
        [FrameAssignment(windowID: window.id, frame: original)],
      ) }
      pumpRunLoop(for: 0.4)
    }

    onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: staged)]) }
    pumpRunLoop(for: 0.25)
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: anchored)],
      asynchronousPositionTimeoutSeconds: 0.05,
      source: "test-strip-sliver"
    ) }
    XCTAssertTrue(
      pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 0.8
      )
    )
    pumpRunLoop(for: 0.1)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    XCTAssertEqual(actual?.x ?? 0, anchored.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, anchored.y, accuracy: 2)
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 0)
  }

  func testReenteringWindowJoinsFirstAnimatedRibbonSample() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windows = testWindows(in: snapshot)
    guard let monitor = snapshot.monitors.first(where: { monitor in
      windows.filter { monitor.physicalFrame.contains(centerOf: $0.frame) }.count >= 2
    }) else {
      throw XCTSkip("Need two manageable desktop windows on the same monitor")
    }
    let monitorWindows = windows.filter { monitor.physicalFrame.contains(centerOf: $0.frame) }
    let window = monitorWindows[0]
    let neighbor = monitorWindows[1]
    let original = window.frame
    let neighborOriginal = neighbor.frame
    let parked = resolveParkingPlacement(
      for: original,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    let target = Rect(
      x: monitor.physicalFrame.x + monitor.physicalFrame.width - original.width - 8,
      y: original.y,
      width: original.width,
      height: original.height
    )
    let neighborTarget = Rect(
      x: neighborOriginal.x - original.width - 16,
      y: neighborOriginal.y,
      width: neighborOriginal.width,
      height: neighborOriginal.height
    )
    defer {
      onNavigation { platform.apply([
        FrameAssignment(windowID: window.id, frame: original),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: parked),
        FrameAssignment(windowID: neighbor.id, frame: neighborOriginal),
      ],
      hiddenWindowIDs: [window.id],
    ) }
    pumpRunLoop(for: 0.3)
    onNavigation { platform.apply(
      [
        FrameAssignment(windowID: window.id, frame: target),
        FrameAssignment(windowID: neighbor.id, frame: neighborTarget),
      ],
      animationDuration: 0.05,
      animationRefreshRateHz: 120,
      source: "command-animation"
    ) }
    pumpRunLoop(for: 0.4)

    let actual = platform.snapshot(config: Config()).windows
      .first(where: { $0.id == window.id })?.frame
    let performance = onNavigation { platform.frameCoordinatorPerformance }
    let maximumAnimationFrames = completedFrameSpringSamples(
      duration: 0.05,
      refreshRateHz: 120
    ).count + 1
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertGreaterThanOrEqual(performance.animationFrames, 2)
    XCTAssertLessThanOrEqual(performance.animationFrames, maximumAnimationFrames)
  }

  func testPostAnimationCommitLagDoesNotTriggerUnanimatedCorrection() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first else {
      throw XCTSkip("No desktop monitor")
    }
    let candidates = testWindows(in: snapshot).filter { window in
      let intersectionWidth = max(
        min(
          window.frame.x + window.frame.width,
          monitor.frame.x + monitor.frame.width
        ) - max(window.frame.x, monitor.frame.x),
        0
      )
      return !window.intrinsicSize
        && intersectionWidth >= window.frame.width * 0.5
    }
    guard !candidates.isEmpty else {
      throw XCTSkip("No manageable desktop window")
    }

    let competingPlatform = try makePlatform()
    _ = competingPlatform.snapshot(config: Config())
    var selected:
      (
        window: Window,
        original: Rect,
        target: Rect,
        expectation: FrameCommitExpectation
      )?
    var failedPreconditions: [String] = []
    for window in candidates.sorted(by: { $0.frame.width > $1.frame.width }) {
      let original = window.frame
      let animatedWidth = max(original.width - 160, 200)
      let target = Rect(
        x: original.x + 80,
        y: original.y,
        width: animatedWidth,
        height: original.height
      )
      let intermediate = Rect(
        x: original.x + 40,
        y: original.y,
        width: animatedWidth,
        height: original.height
      )
      onNavigation { platform.apply(
        [FrameAssignment(windowID: window.id, frame: target)],
        animationDuration: 0.05,
        animationRefreshRateHz: 120,
        source: "test-animation"
      ) }
      guard pumpRunLoop(
        until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } },
        timeout: 0.5
      ) else {
        failedPreconditions.append("\(window.appID):animation")
        onNavigation { competingPlatform.apply([
          FrameAssignment(windowID: window.id, frame: original)
        ]) }
        pumpRunLoop(for: 0.15)
        onNavigation { platform.acceptObservedFrame(original, for: window.id) }
        continue
      }

      var competingWriteConverged = false
      var lastCompetingFrame: Rect?
      for _ in 0..<10 where !competingWriteConverged {
        onNavigation { competingPlatform.apply([
          FrameAssignment(windowID: window.id, frame: intermediate)
        ]) }
        competingWriteConverged = pumpRunLoop(
          until: {
            let actual = competingPlatform.snapshot(config: Config()).windows
              .first(where: { $0.id == window.id })?.frame
            lastCompetingFrame = actual
            return abs((actual?.x ?? .infinity) - intermediate.x) <= 2
          },
          timeout: 0.03
        )
      }
      if competingWriteConverged,
        let expectation = platform.frameCommitExpectations[window.id]
      {
        selected = (window, original, target, expectation)
        break
      }
      failedPreconditions.append(
        "\(window.appID):\(String(describing: lastCompetingFrame))"
      )
      onNavigation { competingPlatform.apply([
        FrameAssignment(windowID: window.id, frame: original)
      ]) }
      pumpRunLoop(for: 0.15)
      onNavigation { platform.acceptObservedFrame(original, for: window.id) }
    }
    guard let selected else {
      XCTFail(
        "test must force a delayed intermediate commit before checking quarantine; attempts=\(failedPreconditions)"
      )
      return
    }
    let window = selected.window
    let original = selected.original
    let target = selected.target
    let expectation = selected.expectation
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: original)]) }
      pumpRunLoop(for: 0.3)
    }
    let observationStartedAt = ProcessInfo.processInfo.systemUptime
    platform.frameCommitExpectations[window.id] = FrameCommitExpectation(
      from: expectation.from,
      target: expectation.target,
      issuedAt: observationStartedAt,
      deadline: observationStartedAt
        + frameCommitQuarantineDuration(
          animationDuration: 0.05,
          initialFrameSettlement: false
        ),
      observedAt: expectation.observedAt
    )

    let writesBeforeDesktopSync = onNavigation { platform.successfulPositionWriteCount }
    onNavigation { platform.requestFrameRefresh(for: window.id) }
    let delayedSnapshot = platform.snapshot(config: Config())
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      source: "desktop-sync"
    ) }
    pumpRunLoop(for: 0.08)

    XCTAssertTrue(delayedSnapshot.targetMismatches.isEmpty)
    XCTAssertGreaterThan(onNavigation { platform.frameCommitPerformance }.deferred, 0)
    XCTAssertEqual(
      onNavigation { platform.successfulPositionWriteCount },
      writesBeforeDesktopSync
    )
    XCTAssertFalse(
      onNavigation { platform.frameCoordinatorTrace }.contains("source=desktop-sync")
    )
  }

  func testNativeFocusEmitsPlatformEvent() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard
      let window = testWindows(in: snapshot).first(
        where: { $0.id != snapshot.focusedWindowID }
      )
    else {
      throw XCTSkip("Need a non-focused manageable window")
    }
    defer {
      if let originalFocusedWindowID = snapshot.focusedWindowID {
        onNavigation { platform.focus(originalFocusedWindowID) }
        pumpRunLoop(for: 0.5)
      }
    }
    let eventCount = DesktopValue(0)
    onNavigation { platform.startObserving {
      DispatchQueue.main.async { eventCount.value += 1 }
    } }

    onNavigation { platform.focus(window.id) }
    pumpRunLoop(for: 0.6)

    XCTAssertGreaterThan(eventCount.value, 0)
    XCTAssertEqual(platform.snapshot(config: Config()).focusedWindowID, window.id)
  }

  func testRapidNativeFocusKeepsLatestIntent() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windows = Array(testWindows(in: snapshot).prefix(2))
    guard windows.count == 2 else {
      throw XCTSkip("Need two manageable windows")
    }
    let originalFocusedWindowID = snapshot.focusedWindowID
    defer {
      if let originalFocusedWindowID {
        onNavigation { platform.focus(originalFocusedWindowID) }
        pumpRunLoop(for: 0.5)
      }
    }

    for windowID in [windows[0].id, windows[1].id, windows[0].id, windows[1].id] {
      onNavigation { platform.focus(windowID) }
    }

    XCTAssertTrue(
      pumpRunLoop(
        until: {
          !onNavigation { platform.hasPendingFocusWrite }
            && platform.snapshot(config: Config()).focusedWindowID
              == windows[1].id
        },
        timeout: 2
      ),
      "stale focus recovery overrode latest rapid focus intent"
    )
  }

  func testSnapshotUsesUniqueWindowIDsPerProcess() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    let windowsByProcess = Dictionary(grouping: snapshot.windows, by: \.processID)

    for (processID, windows) in windowsByProcess {
      XCTAssertEqual(
        Set(windows.map(\.id)).count,
        windows.count,
        "process \(String(describing: processID)) mapped multiple AX windows to one CG window"
      )
    }
  }

  func testSettingsSearchCancelAfterKeyboardSelection() throws {
    _ = try makePlatform()
    let frontmost = NSWorkspace.shared.frontmostApplication
    let originalPolicy = NSApplication.shared.activationPolicy()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 920, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DefiSettingsView(
      configURL: directory.appendingPathComponent("config.toml")))
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(originalPolicy)
      frontmost?.activate()
      try? FileManager.default.removeItem(at: directory)
    }
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    func views(_ root: NSView) -> [NSView] {
      [root] + root.subviews.flatMap(views)
    }
    func descendants() -> [NSView] { window.contentView.map(views) ?? [] }
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().contains { $0 is NSSearchField }
    }, timeout: 2))
    let search = try XCTUnwrap(descendants().compactMap { $0 as? NSSearchField }.first)
    XCTAssertTrue(window.makeFirstResponder(search))
    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    editor.insertText("focus column left", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTableView }.first?.numberOfRows == 2
    }, timeout: 2))
    let down = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
      charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
    NSApplication.shared.sendEvent(down)
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTextField }.contains {
        $0.placeholderString == "Search actions" && $0.stringValue == "focus-column first"
      }
    }, timeout: 2), "Down must select and reveal the actual shortcut action")
    XCTAssertNil(search.currentEditor(), "Down must transfer focus into the results")
    NSApplication.shared.sendEvent(down)
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTextField }.contains {
        $0.placeholderString == "Search actions" && $0.stringValue == "focus-column left"
      }
    }, timeout: 2), "Further arrows must navigate the native result list")
    let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
    let cancel = try XCTUnwrap(cell.cancelButtonCell)
    cancel.performClick(search)
    XCTAssertEqual(search.stringValue, "")
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTableView }.first?.numberOfRows == SettingsPage.allCases.count
    }, timeout: 2), "Native cancel must restore the settings pages after keyboard selection")
    XCTAssertFalse(descendants().compactMap { $0 as? NSTextField }.contains {
      $0.placeholderString == "Search actions" && !$0.stringValue.isEmpty
    }, "Native cancel must remove the exact shortcut filter")
    XCTAssertTrue(window.makeFirstResponder(search))
    let focusedEditor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    focusedEditor.insertText("animation duration", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTableView }.first?.numberOfRows == 1
    }, timeout: 2))
    XCTAssertTrue(search.currentEditor() === focusedEditor, "Typing must retain search focus")
    cancel.performClick(search)
    XCTAssertTrue(pumpRunLoop(until: {
      descendants().compactMap { $0 as? NSTableView }.first?.numberOfRows == SettingsPage.allCases.count
    }, timeout: 2), "Cancel must also restore pages while search remains focused")
  }

  func testShortcutRecorderCapturesKeysAndCancelsWithEscape() throws {
    _ = try makePlatform()
    let frontmost = NSWorkspace.shared.frontmostApplication
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 240, height: 80),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let recorder = ShortcutRecorderButton()
    recorder.shortcutLabel = "⌥A"
    var recorded: [String] = []
    recorder.onRecord = { recorded.append($0) }
    window.contentView = recorder
    defer {
      recorder.stopRecording()
      window.close()
      frontmost?.activate()
    }
    let originalPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)
    defer { NSApplication.shared.setActivationPolicy(originalPolicy) }
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    pumpRunLoop(for: 0.1)
    recorder.performClick(nil)
    XCTAssertTrue(recorder.isRecording)
    XCTAssertTrue(ShortcutRecorderButton.capturesKeyboard)
    let escape = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    NSApplication.shared.sendEvent(escape)
    XCTAssertFalse(recorder.isRecording)
    XCTAssertFalse(ShortcutRecorderButton.capturesKeyboard)
    XCTAssertTrue(recorded.isEmpty)
    recorder.performClick(nil)
    let shortcut = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "a",
      charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    NSApplication.shared.sendEvent(shortcut)
    XCTAssertEqual(recorded, ["alt-ctrl-a"])
    XCTAssertFalse(recorder.isRecording)
    recorder.performClick(nil)
    let physical = try XCTUnwrap(CGEvent(
      keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 125, keyDown: true))
    physical.flags = [.maskControl, .maskAlternate, .maskShift]
    let recordingTracker = UserInputTracker()
    let tap = InputMonitor(
      bindings: [:], userInputTracker: recordingTracker,
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in })
    physical.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
    XCTAssertNil(tap.intercept(type: .keyDown, event: physical))
    XCTAssertEqual(recordingTracker.latestEventTimestamp, Double(physical.timestamp) / 1_000_000_000)
    XCTAssertTrue(pumpRunLoop(until: { recorded.count == 2 }, timeout: 1))
    XCTAssertEqual(recorded.last, "alt-ctrl-shift-down")
    recorder.performClick(nil)
    let manager = onNavigation { HotKeyManager(config: Config()) { _ in } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    physical.post(tap: .cghidEventTap)
    physical.type = .keyUp
    physical.post(tap: .cghidEventTap)
    let recordingDeadline = Date().addingTimeInterval(1)
    while recorded.count < 3, Date() < recordingDeadline {
      if let event = NSApplication.shared.nextEvent(
        matching: .any, until: recordingDeadline, inMode: .default, dequeue: true)
      {
        NSApplication.shared.sendEvent(event)
      }
    }
    XCTAssertEqual(recorded.count, 3)
    XCTAssertFalse(recorder.isRecording)
    recorder.performClick(nil)
    let physicalEscape = try XCTUnwrap(CGEvent(
      keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 53, keyDown: true))
    physicalEscape.post(tap: .cghidEventTap)
    physicalEscape.type = .keyUp
    physicalEscape.post(tap: .cghidEventTap)
    let cancellationDeadline = Date().addingTimeInterval(1)
    while recorder.isRecording, Date() < cancellationDeadline {
      if let event = NSApplication.shared.nextEvent(
        matching: .any, until: cancellationDeadline, inMode: .default, dequeue: true)
      {
        NSApplication.shared.sendEvent(event)
      }
    }
    XCTAssertFalse(recorder.isRecording)
    recorder.performClick(nil)
    physical.type = .keyDown
    XCTAssertNil(tap.intercept(type: .keyDown, event: physical))
    recorder.stopRecording()
    recorder.performClick(nil)
    pumpRunLoop(for: 0.05)
    XCTAssertEqual(recorded.count, 3)
    XCTAssertTrue(recorder.isRecording)
    window.makeFirstResponder(nil)
    XCTAssertFalse(ShortcutRecorderButton.capturesKeyboard)
    XCTAssertNotNil(tap.intercept(type: .keyDown, event: physical))
    recorder.performClick(nil)
    window.close()
    XCTAssertFalse(ShortcutRecorderButton.capturesKeyboard)
  }

  func testSwiftUIMenuKeepsWorkspaceSelectionAndCommandRouting() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let state = MenuBarState(accessibilityTrusted: { true })
    state.update(
      activeWorkspace: "dev",
      workspaces: [MenuWorkspace(id: "dev", label: "Dev"), MenuWorkspace(id: "web", label: "Web")]
    )
    let menu = NSHostingMenu(rootView: MenuBarContent(
      state: state,
      commandHandler: { commands.value.append($0) }
    ))
    menu.update()
    XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
      "Workspaces", "Settings…", "Quit Defi",
    ])
    let settings = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
    XCTAssertNil(settings.image)
    XCTAssertEqual(settings.keyEquivalent, ",")
    XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
    let workspaces = try XCTUnwrap(menu.items.first { $0.title == "Workspaces" }?.submenu)
    workspaces.update()
    XCTAssertEqual(workspaces.items.first { $0.title == "Dev" }?.state, .on)
    let workspaceIndex = try XCTUnwrap(workspaces.items.firstIndex { $0.title == "Web" })
    workspaces.performActionForItem(at: workspaceIndex)
    pumpRunLoop(for: 0.05)
    let quitIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Quit Defi" })
    menu.performActionForItem(at: quitIndex)
    pumpRunLoop(for: 0.05)
    XCTAssertEqual(commands.value, ["workspace web", "quit"])
  }

  func testCheatsheetFitsContentAndNeverRestoresAClosedPanelOrTakesFocus() throws {
    _ = try makePlatform()
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let controller = CheatsheetController(config: Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], defaultKeyModifier: "hyper"
    ))
    defer { controller.close() }
    controller.show(on: nil)
    let first = try XCTUnwrap(NSApplication.shared.windows.first {
      $0.title == "Defi keyboard shortcuts" && $0.isVisible
    })
    XCTAssertFalse(first.canBecomeKey)
    XCTAssertFalse(first.canBecomeMain)
    XCTAssertFalse(first.styleMask.contains(.titled))
    controller.close()
    controller.show(on: nil)
    pumpRunLoop(for: 0.3)
    XCTAssertFalse(first.isVisible)
    let current = try XCTUnwrap(NSApplication.shared.windows.first {
      $0.title == "Defi keyboard shortcuts" && $0.isVisible
    })
    XCTAssertEqual(current.alphaValue, 1, accuracy: 0.01)
    XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
    let screen = try XCTUnwrap(current.screen)
    XCTAssertLessThan(current.frame.height, screen.visibleFrame.height - 48)
    XCTAssertLessThan(current.frame.width, screen.visibleFrame.width - 48)
    XCTAssertGreaterThan(current.frame.width, 600)
    let fittedFrame = current.frame
    pumpRunLoop(for: 0.2)
    XCTAssertEqual(current.frame, fittedFrame)
    XCTAssertEqual(current.frame.midX, screen.visibleFrame.midX, accuracy: 1)
    XCTAssertEqual(current.frame.midY, screen.visibleFrame.midY, accuracy: 1)
    controller.close()
    pumpRunLoop(for: 0.2)
    XCTAssertFalse(current.isVisible)
  }

  func testCheatsheetReceivesHeldModifierAndCapturesItsShortcut() throws {
    _ = try makePlatform()
    let inputs = DesktopValue<[CheatsheetInput]>([])
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(
      config: Config(
        modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
        defaultKeyModifier: "hyper",
        keys: ["hyper-slash": "toggle-cheatsheet"]
      ),
      cheatsheetHandler: { value in DispatchQueue.main.async { inputs.value.append(value) } }
    ) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    let modifier = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 58, keyDown: true
    ))
    modifier.type = .flagsChanged
    modifier.flags = [.maskAlternate, .maskCommand, .maskControl]
    defer {
      modifier.flags = []
      modifier.post(tap: .cghidEventTap)
      pumpRunLoop(for: 0.1)
    }
    modifier.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      inputs.value.contains(.modifiersChanged(matches: true, released: false))
    }, timeout: 1))
    pumpRunLoop(for: 0.65)
    XCTAssertEqual(inputs.value.last, .modifiersChanged(matches: true, released: false))
    let shortcut = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 44, keyDown: true
    ))
    shortcut.flags = modifier.flags
    shortcut.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { commands.value == ["toggle-cheatsheet"] }, timeout: 1))
    shortcut.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    shortcut.post(tap: .cghidEventTap)
    pumpRunLoop(for: 0.1)
    XCTAssertEqual(commands.value, ["toggle-cheatsheet"])
    onNavigation { manager.setCheatsheetVisible(true) }
    let escape = try XCTUnwrap(CGEvent(
      keyboardEventSource: source, virtualKey: 53, keyDown: true
    ))
    escape.flags = modifier.flags
    escape.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { inputs.value.last == .dismiss }, timeout: 1))
  }

  func testHotKeysAreCapturedWhileMainActorIsBlocked() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    let tracker = UserInputTracker()
    let received = Mutex<[HotKeyInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      userInputTracker: tracker
    ) { invocation in
      received.withLock { $0.append(invocation) }
    } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let eventCount = 8

    DispatchQueue.global(qos: .userInteractive).async {
      Thread.sleep(forTimeInterval: 0.05)
      let flags: CGEventFlags = [
        .maskAlternate,
        .maskCommand,
        .maskControl,
      ]
      for _ in 0..<eventCount {
        guard
          let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: 123,
            keyDown: true
          )
        else {
          continue
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        if let modifierRelease = CGEvent(
          keyboardEventSource: source,
          virtualKey: 59,
          keyDown: false
        ) {
          modifierRelease.type = .flagsChanged
          modifierRelease.flags = []
          modifierRelease.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }

    Thread.sleep(forTimeInterval: 0.35)
    XCTAssertEqual(
      onNavigation { manager.capturedKeyCount },
      eventCount,
      "event tap must keep capturing while AX/layout blocks the main actor"
    )
    let invocations = received.withLock { $0 }
    XCTAssertEqual(invocations.count, eventCount,
      "commands must be delivered before the main actor resumes")
    XCTAssertTrue(invocations.allSatisfy { $0.command == "focus-column left" })
    XCTAssertTrue(invocations.allSatisfy { $0.timestamp > 0 })
    XCTAssertEqual(tracker.latestEventTimestamp, invocations.last?.timestamp)
    XCTAssertEqual(onNavigation { manager.tapReenableCount }, 0)
  }

  func testRegisteredHotKeysRemainObservableAndRepeatWithoutForegroundLeak() throws {
    _ = try makePlatform()
    let commands = Mutex<[HotKeyInvocation]>([])
    let manager = onNavigation { HotKeyManager(config: Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      defaultKeyModifier: "hyper", keys: ["hyper-slash": "focus-column right"]
    )) { invocation in commands.withLock { $0.append(invocation) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }

    let observer = DesktopHotKeyObserver()
    let tap = try XCTUnwrap(CGEvent.tapCreate(
      tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
      eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
      callback: { _, type, event, pointer in
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 44,
          let pointer {
          let observer = Unmanaged<DesktopHotKeyObserver>.fromOpaque(pointer).takeUnretainedValue()
          observer.repeats.withLock {
            $0.append(event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
          }
        }
        return Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(observer).toOpaque()
    ))
    let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(nil, tap, 0))
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    defer {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFMachPortInvalidate(tap)
      withExtendedLifetime(observer) {}
    }
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 200, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let originalPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(originalPolicy)
      // Settle activation/close events before a later test opens its recorder.
      pumpApplicationEvents(for: 0.1)
    }
    let foregroundCount = DesktopValue(0)
    let localMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 44 {
        foregroundCount.value += 1
        return nil
      }
      return event
    })
    defer { NSEvent.removeMonitor(localMonitor) }
    pumpRunLoop(for: 0.1)
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 44, keyDown: true))
    event.flags = [.maskControl, .maskAlternate, .maskCommand]
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { commands.withLock { $0.count == 1 }
      && observer.repeats.withLock { $0.count == 1 } }, timeout: 1))
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { commands.withLock { $0.count == 2 }
      && observer.repeats.withLock { $0.count == 2 } }, timeout: 1))
    event.type = .keyUp
    event.post(tap: .cghidEventTap)
    pumpApplicationEvents(for: 0.1)
    XCTAssertEqual(observer.repeats.withLock { $0 }, [false, true])
    XCTAssertEqual(commands.withLock { $0.map(\.command) }, ["focus-column right", "focus-column right"])
    XCTAssertEqual(foregroundCount.value, 0, "Carbon must reserve the shortcut from the foreground app")

    onNavigation { manager.stop() }
    pumpRunLoop(for: 0.1)
    event.type = .keyDown
    event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    event.post(tap: .cghidEventTap)
    event.type = .keyUp
    event.post(tap: .cghidEventTap)
    let deadline = Date().addingTimeInterval(1)
    while foregroundCount.value == 0, Date() < deadline {
      if let next = NSApplication.shared.nextEvent(matching: .any, until: deadline,
                                                  inMode: .default, dequeue: true) {
        NSApplication.shared.sendEvent(next)
      }
    }
    XCTAssertEqual(foregroundCount.value, 1, "Stopping must release the Carbon reservation")
    XCTAssertEqual(commands.withLock { $0.count }, 2)
  }

  func testCarbonReservationsSuspendAndResumeAroundRecordingAndTextEditing() throws {
    _ = try makePlatform()
    let commands = Mutex<[HotKeyInvocation]>([])
    let manager = onNavigation { HotKeyManager(config: Config(
      keys: ["ctrl-alt-cmd-slash": "focus-column right"]
    )) { invocation in commands.withLock { $0.append(invocation) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let key = try Key(accelerator: "ctrl-alt-cmd-slash", aliases: [:])
    let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 150),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let originalPolicy = NSApplication.shared.activationPolicy()
    NSApplication.shared.setActivationPolicy(.regular)
    let recorded = DesktopValue<[String]>([])
    let recorder = ShortcutRecorderButton()
    recorder.frame = NSRect(x: 10, y: 10, width: 150, height: 30)
    recorder.shortcutLabel = "ctrl-alt-cmd-slash"
    recorder.onRecord = { recorded.value.append($0) }
    let text = NSTextView(frame: NSRect(x: 10, y: 50, width: 250, height: 60))
    window.contentView?.addSubview(recorder)
    window.contentView?.addSubview(text)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate()
    defer {
      recorder.stopRecording()
      window.close()
      settingsTextInputFocused.withLock { $0 = false }
      NSApplication.shared.setActivationPolicy(originalPolicy)
      pumpApplicationEvents(for: 0.1)
    }
    pumpApplicationEvents(for: 0.1)
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true))
    event.flags = [.maskControl, .maskAlternate, .maskCommand]
    func press() {
      event.type = .keyDown
      event.post(tap: .cghidEventTap)
      event.type = .keyUp
      event.post(tap: .cghidEventTap)
    }
    func assertReservationReleased() {
      var reference: EventHotKeyRef?
      XCTAssertEqual(RegisterEventHotKey(
        UInt32(key.code), key.carbonModifiers, EventHotKeyID(signature: 0x54657374, id: 3),
        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference), noErr)
      if let reference { UnregisterEventHotKey(reference) }
    }
    press()
    XCTAssertTrue(pumpRunLoop(until: { commands.withLock { $0.count == 1 } }, timeout: 1))
    recorder.performClick(nil)
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { manager.isHotKeyCaptureEnabled } }, timeout: 1))
    assertReservationReleased()
    press()
    let deadline = Date().addingTimeInterval(1)
    while recorder.isRecording, Date() < deadline { pumpApplicationEvents(for: 0.02) }
    XCTAssertEqual(recorded.value, ["alt-cmd-ctrl-slash"])
    XCTAssertEqual(commands.withLock { $0.count }, 1)
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { manager.isHotKeyCaptureEnabled } }, timeout: 1))
    press()
    XCTAssertTrue(pumpRunLoop(until: { commands.withLock { $0.count == 2 } }, timeout: 1))

    window.makeFirstResponder(text)
    settingsTextInputFocused.withLock { $0 = true }
    XCTAssertTrue(pumpRunLoop(until: { !onNavigation { manager.isHotKeyCaptureEnabled } }, timeout: 1))
    assertReservationReleased()
    let foregroundCount = DesktopValue(0)
    let localMonitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == key.code { foregroundCount.value += 1; return nil }
      return event
    })
    defer { NSEvent.removeMonitor(localMonitor) }
    press()
    let editingDeadline = Date().addingTimeInterval(1)
    while foregroundCount.value == 0, Date() < editingDeadline { pumpApplicationEvents(for: 0.02) }
    XCTAssertEqual(foregroundCount.value, 1)
    XCTAssertEqual(commands.withLock { $0.count }, 2)
    window.makeFirstResponder(recorder)
    settingsTextInputFocused.withLock { $0 = false }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { manager.isHotKeyCaptureEnabled } }, timeout: 1))
    press()
    XCTAssertTrue(pumpRunLoop(until: { commands.withLock { $0.count == 3 } }, timeout: 1))
    pumpApplicationEvents(for: 0.05)
    XCTAssertEqual(foregroundCount.value, 1)
  }

  func testDuplicateTapDisableNotificationsRecoverOnlyOnce() throws {
    _ = try makePlatform()
    let recoveries = Mutex(0)
    let dismissals = Mutex(0)
    let monitor = InputMonitor(
      bindings: [:], userInputTracker: UserInputTracker(),
      pointerMotionTracker: PointerMotionTracker(), tracksPointerWindowTransitions: false,
      deliverCheatsheet: { _ in dismissals.withLock { $0 += 1 } },
      deliver: { _ in }, deliverOverview: { _ in }, deliverPointerMotion: { _ in },
      tapReenabled: { _ in recoveries.withLock { $0 += 1 } })
    defer { monitor.stop() }
    for options in [CGEventTapOptions.defaultTap, .listenOnly] {
      let port = try monitor.installTap(
        options: options, mask: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: { _, _, event, _ in Unmanaged.passUnretained(event) })
      CGEvent.tapEnable(tap: port, enable: false)
    }
    let event = try XCTUnwrap(CGEvent(source: nil))
    XCTAssertFalse(monitor.isEnabled)
    _ = monitor.intercept(type: .tapDisabledByUserInput, event: event)
    XCTAssertTrue(monitor.isEnabled)
    _ = monitor.handle(type: .tapDisabledByUserInput, event: event)
    XCTAssertEqual(monitor.tapReenableCount, 1)
    XCTAssertEqual(recoveries.withLock { $0 }, 1)
    XCTAssertEqual(dismissals.withLock { $0 }, 1)
  }

  func testCarbonRegistrationFailureKeepsObservationAndRollsBackReservations() throws {
    _ = try makePlatform()
    let key = try Key(accelerator: "ctrl-alt-cmd-slash", aliases: [:])
    var reference: EventHotKeyRef?
    XCTAssertEqual(RegisterEventHotKey(
      UInt32(key.code), key.carbonModifiers, EventHotKeyID(signature: 0x54657374, id: 1),
      GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference), noErr)
    let reserved = try XCTUnwrap(reference)
    defer { UnregisterEventHotKey(reserved) }
    let commands = Mutex<[HotKeyInvocation]>([])
    let tracker = UserInputTracker()
    let manager = onNavigation { HotKeyManager(config: Config(
      keys: ["ctrl-alt-cmd-a": "focus-column left",
             "ctrl-alt-cmd-slash": "focus-column right"]), userInputTracker: tracker
    ) { invocation in commands.withLock { $0.append(invocation) } } }
    try onNavigation { try manager.start() }
    defer { onNavigation { manager.stop() } }
    XCTAssertTrue(pumpRunLoop(until: { onNavigation { manager.bindingError != nil } }, timeout: 1))
    XCTAssertTrue(onNavigation { manager.isEnabled })
    XCTAssertFalse(onNavigation { manager.isHotKeyCaptureEnabled })
    guard case .registrationFailed(keyCode: key.code, status: _) = onNavigation({ manager.bindingError }) else {
      return XCTFail("Expected a Carbon reservation error")
    }
    // The A reservation sorts before slash and must be released by rollback.
    let earlierKey = try Key(accelerator: "ctrl-alt-cmd-a", aliases: [:])
    XCTAssertLessThan(earlierKey.code, key.code)
    var rolledBackReference: EventHotKeyRef?
    let rollbackStatus = RegisterEventHotKey(
      UInt32(earlierKey.code), earlierKey.carbonModifiers,
      EventHotKeyID(signature: 0x54657374, id: 2), GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &rolledBackReference)
    XCTAssertEqual(rollbackStatus, noErr, "A reservation must be released after slash fails")
    if let rolledBackReference { UnregisterEventHotKey(rolledBackReference) }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
    event.flags = [.maskAlternate]
    event.post(tap: .cghidEventTap)
    event.type = .keyUp
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { tracker.latestEventTimestamp > 0 }, timeout: 1))
    XCTAssertTrue(commands.withLock { $0.isEmpty })
  }

  func testWorkspaceMonitorShortcutsAreCaptured() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(config: Config()) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
    for (index, direction) in ["left", "right", "down", "up"].enumerated() {
      let event = try XCTUnwrap(CGEvent(
        keyboardEventSource: source, virtualKey: CGKeyCode(123 + index), keyDown: true
      ))
      event.flags = [.maskControl, .maskAlternate, .maskShift]
      event.post(tap: .cghidEventTap)
      XCTAssertTrue(pumpRunLoop(until: { commands.value.count == index + 1 }, timeout: 1))
      event.type = .keyUp
      event.flags = []
      event.post(tap: .cghidEventTap)
      XCTAssertEqual(commands.value.last, "move-workspace-to-monitor \(direction)")
    }
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 4)
  }

  func testAliasedOverrideWinsOverFixedMonitorShortcut() throws {
    _ = try makePlatform()
    let commands = DesktopValue<[String]>([])
    let manager = onNavigation { HotKeyManager(config: Config(
      modifierCombinations: ["combo": "Ctrl + Alt + Shift"],
      keys: ["combo-left": "focus-column first"]
    )) { value in DispatchQueue.main.async { commands.value.append(value.command) } } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let event = try XCTUnwrap(CGEvent(
      keyboardEventSource: nil, virtualKey: 123, keyDown: true
    ))
    event.flags = [.maskControl, .maskAlternate, .maskShift]
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: { !commands.value.isEmpty }, timeout: 1))
    event.type = .keyUp
    event.flags = []
    event.post(tap: .cghidEventTap)
    XCTAssertEqual(commands.value, ["focus-column first"])
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 1)
  }

  func testConfiguredHyperArrowNavigatesOverview() throws {
    _ = try makePlatform()
    let config = Config(
      modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"],
      keys: ["hyper-left": "focus-column left"]
    )
    let commands = DesktopValue<[HotKeyInvocation]>([])
    let overviewActions = DesktopValue<[OverviewKeyAction]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      overviewHandler: { value in DispatchQueue.main.async { overviewActions.value.append(value) } }
    ) { value in DispatchQueue.main.async { commands.value.append(value) } } }
    try startHotKeys(manager)
    onNavigation { manager.setOverviewModeEnabled(true) }

    DispatchQueue.global(qos: .userInteractive).async {
      Thread.sleep(forTimeInterval: 0.05)
      guard
        let source = CGEventSource(stateID: .hidSystemState),
        let event = CGEvent(
          keyboardEventSource: source,
          virtualKey: 123,
          keyDown: true
        )
      else { return }
      event.flags = [.maskAlternate, .maskCommand, .maskControl]
      event.post(tap: .cghidEventTap)
    }

    XCTAssertTrue(
      pumpRunLoop(until: { overviewActions.value == [.left] }, timeout: 1)
    )
    XCTAssertEqual(commands.value, [])
    XCTAssertEqual(onNavigation { manager.capturedKeyCount }, 1)
  }

  func testConfiguredHyperWorkspaceBindingsNavigateOverview() throws {
    _ = try makePlatform()
    let config = Config(modifierCombinations: ["hyper": "Alt + Cmd + Ctrl"], keys: [
      "hyper-1": "workspace dev", "hyper-2": "focus-workspace-position 2",
      "hyper-3": "focus-workspace-name web"])
    let commands = DesktopValue<[HotKeyInvocation]>([])
    let actions = DesktopValue<[OverviewKeyAction]>([])
    let manager = onNavigation { HotKeyManager(config: config,
      overviewHandler: { value in DispatchQueue.main.async { actions.value.append(value) } }
    ) { value in DispatchQueue.main.async { commands.value.append(value) } } }
    try onNavigation { try manager.start() }
    onNavigation { manager.setOverviewModeEnabled(true) }
    let expected: [OverviewKeyAction] = [.workspace(.named("dev")),
      .workspace(.position(2)), .workspace(.named("web"))]
    for (index, key) in [CGKeyCode(18), 19, 20].enumerated() {
      let event = try XCTUnwrap(CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
        virtualKey: key, keyDown: true))
      event.flags = [.maskAlternate, .maskCommand, .maskControl]
      event.post(tap: .cghidEventTap)
      XCTAssertTrue(pumpRunLoop(until: { actions.value.count == index + 1 }, timeout: 1))
    }
    XCTAssertEqual(actions.value, expected)
    XCTAssertTrue(commands.value.isEmpty, "Workspace shortcuts must not mutate the native workspace during overview")
  }

  func testOverviewCancelBypassesBusyNavigationActor() throws {
    _ = try makePlatform()
    let closed = DesktopValue(false)
    let manager = onNavigation { HotKeyManager(config: Config(),
      overviewCancelHandler: { DispatchQueue.main.async { closed.value = true } }
    ) { _ in } }
    try onNavigation { try manager.start() }
    onNavigation { manager.setOverviewModeEnabled(true) }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    NavigationActor.enqueue {
      entered.signal()
      release.wait()
    }
    defer {
      release.signal()
      onNavigation { manager.stop() }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global(qos: .userInteractive).async {
      guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true) else { return }
      event.post(tap: .cghidEventTap)
    }
    XCTAssertTrue(pumpRunLoop(until: { closed.value }, timeout: 1),
      "Escape must reach the overview without waiting for the AX/navigation lane")
  }

  func testScrollWheelAdvancesUserInputTracker() throws {
    _ = try makePlatform()
    let tracker = UserInputTracker()
    let manager = onNavigation { HotKeyManager(
      config: Config(),
      userInputTracker: tracker
    ) { _ in } }
    try startHotKeys(manager)
    let previousTimestamp = tracker.latestEventTimestamp

    guard let source = CGEventSource(stateID: .hidSystemState),
      let scroll = CGEvent(
        scrollWheelEvent2Source: source,
        units: .pixel,
        wheelCount: 1,
        wheel1: 1,
        wheel2: 0,
        wheel3: 0
      )
    else {
      XCTFail("Could not create scroll-wheel event")
      return
    }
    scroll.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(
        until: { tracker.latestEventTimestamp > previousTimestamp },
        timeout: 0.5
      ),
      "scroll-wheel input did not reach UserInputTracker"
    )
  }

  func testPointerTransitionsUseWindowUnderPointerAndWarpDoesNotLoop() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first,
      let focusedWindowID = snapshot.focusedWindowID,
      let focusedWindow = snapshot.windows.first(where: {
        $0.id == focusedWindowID
      }),
      let originalCursorLocation = CGEvent(source: nil)?.location
    else {
      throw XCTSkip("Focused on-screen managed window required")
    }
    defer {
      CGWarpMouseCursorPosition(originalCursorLocation)
    }

    let config = Config(
      input: InputConfig(
        focusFollowsMouse: true,
        mouseFollowsFocus: true
      )
    )
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      pointerMotionTracker: platform.pointerMotionTracker,
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      }
    ) { _ in } }
    try startHotKeys(manager)

    let focusedCenter = CGPoint(
      x: focusedWindow.frame.x + focusedWindow.frame.width / 2,
      y: focusedWindow.frame.y + min(20, focusedWindow.frame.height / 2)
    )
    XCTAssertEqual(CGWarpMouseCursorPosition(focusedCenter), .success)
    guard
      let source = CGEventSource(stateID: .hidSystemState),
      let movement = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: focusedCenter,
        mouseButton: .left
      )
    else {
      XCTFail("Could not create mouse movement event")
      return
    }
    movement.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(until: { !received.value.isEmpty }, timeout: 0.5),
      "mouse movement did not reach event tap"
    )
    pumpRunLoop(for: 0.1)
    let resolvedPointerWindowID = received.value.last.flatMap {
      $0.windowID ?? platform.managedWindowID(at: $0.location)
    }
    XCTAssertEqual(resolvedPointerWindowID, focusedWindowID)
    guard let currentCursorLocation = CGEvent(source: nil)?.location,
      let otherWindow = snapshot.windows.first(where: { window in
        window.id != focusedWindowID
          && window.frame.x + window.frame.width / 2 >= monitor.frame.x
          && window.frame.y + window.frame.height / 2 >= monitor.frame.y
          && window.frame.x + window.frame.width / 2
            <= monitor.frame.x + monitor.frame.width
          && window.frame.y + window.frame.height / 2
            <= monitor.frame.y + monitor.frame.height
          && cursorWarpDestination(
            frame: window.frame,
            currentLocation: currentCursorLocation
          ) != nil
      })
    else {
      throw XCTSkip("Second on-screen managed window required")
    }
    let transitionsBeforeWarp = onNavigation { manager.pointerTransitionCount }

    onNavigation { platform.warpCursor(
      to: otherWindow.id,
      unlessUserInputAfter: .greatestFiniteMagnitude
    ) }
    pumpRunLoop(for: 0.2)

    XCTAssertEqual(onNavigation { platform.cursorWarpPerformance }.applied, 1)
    XCTAssertEqual(
      onNavigation { manager.pointerTransitionCount },
      transitionsBeforeWarp,
      "programmatic cursor warp must not emit pointer transitions"
    )
  }

  func testFrameCommitWarpsCursorForAcceptedNativeFocus() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let monitor = snapshot.monitors.first,
      let window = testWindows(in: snapshot).first,
      let originalCursorLocation = CGEvent(source: nil)?.location
    else {
      throw XCTSkip("Managed desktop window required")
    }
    let originalFrame = window.frame
    let targetFrame = Rect(
      x: originalFrame.x + 10,
      y: originalFrame.y,
      width: originalFrame.width,
      height: originalFrame.height
    )
    let outsideCandidates = [
      CGPoint(x: monitor.frame.x + 1, y: monitor.frame.y + 1),
      CGPoint(
        x: monitor.frame.x + monitor.frame.width - 1,
        y: monitor.frame.y + 1
      ),
      CGPoint(
        x: monitor.frame.x + 1,
        y: monitor.frame.y + monitor.frame.height - 1
      ),
      CGPoint(
        x: monitor.frame.x + monitor.frame.width - 1,
        y: monitor.frame.y + monitor.frame.height - 1
      ),
    ]
    guard let outside = outsideCandidates.first(where: {
      cursorWarpDestination(frame: targetFrame, currentLocation: $0) != nil
    }) else {
      throw XCTSkip("Window covers the usable monitor")
    }
    defer {
      onNavigation { platform.apply([
        FrameAssignment(windowID: window.id, frame: originalFrame)
      ]) }
      CGWarpMouseCursorPosition(originalCursorLocation)
      pumpRunLoop(for: 0.3)
    }

    XCTAssertEqual(CGWarpMouseCursorPosition(outside), .success)
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: targetFrame)],
      cursorWarpWindowIDAfterCommit: window.id,
      cursorWarpInputTimestampAfterCommit: .greatestFiniteMagnitude,
      cursorWarpIsCurrentAfterCommit: { true }
    ) }

    XCTAssertTrue(
      pumpRunLoop(
        until: { onNavigation { platform.cursorWarpPerformance }.applied == 1 },
        timeout: 1
      ),
      "cursor did not warp after the target frame committed; performance=\(onNavigation { platform.cursorWarpPerformance }) trace=\(onNavigation { platform.frameCoordinatorTrace })"
    )
  }

  func testPointerTrackingStartsWhenHotKeyParsingFails() throws {
    _ = try makePlatform()
    let config = Config(
      input: InputConfig(focusFollowsMouse: true),
      keys: ["unknown-no-such-key": "focus-column left"]
    )
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let manager = onNavigation { HotKeyManager(
      config: config,
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      }
    ) { _ in } }
    XCTAssertNotNil(onNavigation { manager.bindingError })
    XCTAssertEqual(onNavigation { manager.bindingCount }, 0)
    try startHotKeys(manager)

    guard let location = CGEvent(source: nil)?.location,
      let source = CGEventSource(stateID: .hidSystemState),
      let movement = CGEvent(
        mouseEventSource: source,
        mouseType: .mouseMoved,
        mouseCursorPosition: location,
        mouseButton: .left
      )
    else {
      XCTFail("Could not create mouse movement event")
      return
    }
    movement.post(tap: .cghidEventTap)

    XCTAssertTrue(
      pumpRunLoop(until: { !received.value.isEmpty }, timeout: 0.5),
      "pointer movement did not survive invalid hotkey parsing"
    )
  }

  func testCornerParkingConvergesWithRealWindowFrame() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let target = resolveParkingPlacement(
      for: window.frame,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }

    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: target)],
      hiddenWindowIDs: [window.id],
    ) }
    let element = try XCTUnwrap(platform.elements[window.id])
    var actual: Rect?
    XCTAssertTrue(pumpRunLoop(until: {
      actual = platform.frame(of: element)
      return actual.map { abs($0.x - target.x) <= 2 && abs($0.y - target.y) <= 2 } == true
    }, timeout: 1.5), "the native frame must converge, independently of the snapshot refresh budget")
    XCTAssertFalse(onNavigation { platform.hasPendingAnimatedFrameWrites })
    XCTAssertEqual(actual?.x ?? 0, target.x, accuracy: 2)
    XCTAssertEqual(actual?.y ?? 0, target.y, accuracy: 2)
    XCTAssertEqual(onNavigation { platform.hiddenWindowCount }, 1)
  }

  func testIsolatedDisplayArrangementPreservesPartialRibbonAndRestores() throws {
    let platform = try makePlatform()
    let initialFrames = DisplayArrangementController.currentFrames()
    guard initialFrames.count > 1 else { throw XCTSkip("Requires two connected displays") }
    let initial = platform.snapshot(config: Config())
    let window = try XCTUnwrap(testWindows(in: initial).first)
    let initialPointer = CGEvent(source: nil)?.location
    let controller = DisplayArrangementController()
    defer {
      controller.restore()
      XCTAssertEqual(DisplayArrangementController.apply(initialFrames, scope: .forSession), .success)
      pumpRunLoop(for: 0.3)
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      if let initialPointer { CGWarpMouseCursorPosition(initialPointer) }
      XCTAssertEqual(DisplayArrangementController.currentFrames(), initialFrames)
    }
    // Exercise the transformed arrangement even when the user's displays are vertical.
    let primary = MonitorID(rawValue: UInt64(CGMainDisplayID()))
    var deskFrames = initialFrames
    var nextX = try XCTUnwrap(initialFrames[primary]).width
    for id in initialFrames.keys.sorted(by: { $0.rawValue < $1.rawValue }) where id != primary {
      deskFrames[id]?.x = nextX
      deskFrames[id]?.y = 0
      nextX += initialFrames[id]!.width
    }
    XCTAssertEqual(DisplayArrangementController.apply(deskFrames), .success)
    pumpRunLoop(for: 0.3)
    XCTAssertEqual(DisplayArrangementController.currentFrames(), deskFrames)
    _ = controller.reconcile()
    XCTAssertEqual(controller.status, "isolated")
    pumpRunLoop(for: 0.3)
    let monitors = platform.discoverMonitors()
    XCTAssertEqual(controller.deskFrames, deskFrames)
    let technical = DisplayArrangementController.currentFrames()
    var crossings = 0
    for frame in technical.values {
      let edges: [(Double, Double, Double, Double)] = [
        (frame.x, frame.y + frame.height / 2, -5, 0),
        (frame.x + frame.width - 1, frame.y + frame.height / 2, 5, 0),
        (frame.x + frame.width / 2, frame.y, 0, -5),
        (frame.x + frame.width / 2, frame.y + frame.height - 1, 0, 5),
      ]
      for (x, y, dx, dy) in edges {
        guard let expected = displayPointerDestination(
          x: x, y: y, deltaX: dx, deltaY: dy, technical: technical, desk: deskFrames
        ) else { continue }
        let event = try XCTUnwrap(CGEvent(
          mouseEventSource: nil, mouseType: .mouseMoved,
          mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left
        ))
        event.setDoubleValueField(.mouseEventDeltaX, value: dx)
        event.setDoubleValueField(.mouseEventDeltaY, value: dy)
        XCTAssertTrue(controller.pointerRouter.route(event))
        let observed = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(observed.x, expected.x, accuracy: 2)
        XCTAssertEqual(observed.y, expected.y, accuracy: 2)
        crossings += 1
      }
    }
    XCTAssertGreaterThan(crossings, 0)
    for monitor in monitors {
      let frame = monitor.frame
      let target = Rect(
        x: frame.x + frame.width * 0.8, y: frame.y,
        width: window.frame.width, height: min(window.frame.height, frame.height)
      )
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: target)]) }
      pumpRunLoop(for: 0.2)
      let element = try XCTUnwrap(platform.elements[window.id])
      let actual = try XCTUnwrap(platform.frame(of: element))
      XCTAssertEqual(actual.x, target.x, accuracy: 2)
      XCTAssertEqual(actual.width, target.width, accuracy: 2)
      let rect = CGRect(x: actual.x, y: actual.y, width: actual.width, height: actual.height)
      let visible = rect.intersection(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
      XCTAssertGreaterThan(visible.width, 100, "The neighboring column's preview disappeared")
      for other in monitors where other.id != monitor.id {
        let neighbor = other.physicalFrame
        let overlap = rect.intersection(CGRect(x: neighbor.x, y: neighbor.y, width: neighbor.width, height: neighbor.height))
        XCTAssertTrue(overlap.isNull || overlap.isEmpty, "Partial ribbon leaked onto another display")
      }
    }
    XCTAssertEqual(controller.restore(), deskFrames)
  }

  func testMonitorTransferFillsDestinationHeight() throws {
    let platform = try makePlatform()
    // Match the running daemon's geometry; stopping it now restores the desk.
    let arrangement = DisplayArrangementController()
    defer { arrangement.restore() }
    if arrangement.reconcile() { pumpRunLoop(for: 0.3) }
    let snapshot = platform.snapshot(config: Config())
    let monitors = snapshot.monitors.sorted { $0.frame.height < $1.frame.height }
    guard let smaller = monitors.first, let taller = monitors.last,
      taller.frame.height - smaller.frame.height > 10
    else { throw XCTSkip("Requires two monitors with different usable heights") }
    let window = try XCTUnwrap(testWindows(in: snapshot).first)
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }

    for invalidatesDisplayState in [false, true] {
      for monitor in [smaller, taller, smaller] {
        if invalidatesDisplayState { onNavigation { platform.invalidateFrameStateForDisplayChange() } }
        let target = Rect(
          x: monitor.frame.x, y: monitor.frame.y,
          width: min(window.frame.width, monitor.frame.width),
          height: monitor.frame.height
        )
        onNavigation { platform.apply(
          [FrameAssignment(windowID: window.id, frame: target)],
          animationDuration: invalidatesDisplayState ? 0 : 0.035,
          animateSizeChanges: !invalidatesDisplayState,
          source: "test-monitor-height"
        ) }
        XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingFrameWrites } }, timeout: 2))
        let element = try XCTUnwrap(platform.elements[window.id])
        var actual: Rect?
        XCTAssertTrue(pumpRunLoop(until: {
          actual = platform.frame(of: element)
          return actual.map { abs($0.height - target.height) <= 2 && abs($0.y - target.y) <= 2 } == true
        }, timeout: 1), "monitor=\(monitor.id) invalidated=\(invalidatesDisplayState) target=\(target) actual=\(String(describing: actual)) trace=\(onNavigation { platform.frameCoordinatorTrace })")
      }
    }
  }

  func testDisplayCrossingDeliversDestinationMotionWithoutAnotherEvent() throws {
    _ = try makePlatform()
    let original = DisplayArrangementController.currentFrames()
    guard original.count == 2 else { throw XCTSkip("Requires two monitors") }
    let cursor = try XCTUnwrap(CGEvent(source: nil)?.location)
    let primary = MonitorID(rawValue: UInt64(CGMainDisplayID()))
    let other = try XCTUnwrap(original.keys.first { $0 != primary })
    var desk = original
    let sourceFrame = try XCTUnwrap(original[primary])
    desk[other]?.x = sourceFrame.x + sourceFrame.width
    desk[other]?.y = sourceFrame.y
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    func makeController() -> DisplayArrangementController {
      DisplayArrangementController(
        readFrames: DisplayArrangementController.currentFrames,
        applyFrames: DisplayArrangementController.apply, primaryDisplay: { primary },
        stateURL: directory.appending(path: "arrangement.json"), sessionID: "desktop-test"
      )
    }
    var controller = makeController()
    defer {
      controller.restore()
      XCTAssertEqual(DisplayArrangementController.apply(original, scope: .forSession), .success)
      CGWarpMouseCursorPosition(cursor)
    }
    XCTAssertEqual(DisplayArrangementController.apply(desk), .success)
    pumpRunLoop(for: 0.3)
    _ = controller.reconcile()
    let technical = DisplayArrangementController.currentFrames()
    controller.restore()
    XCTAssertEqual(DisplayArrangementController.apply(technical), .success)
    controller = makeController()
    _ = controller.reconcile()
    XCTAssertEqual(controller.deskFrames, desk)
    let source = try XCTUnwrap(technical[primary])
    let x = source.x + source.width - 1
    let y = source.y + min(source.height, original[other]!.height) / 2
    let destination = try XCTUnwrap(displayPointerDestination(
      x: x, y: y, deltaX: 5, deltaY: 0, technical: technical, desk: desk
    ))
    let received = DesktopValue<[PointerMotionInvocation]>([])
    let pointerRouter = controller.pointerRouter
    let manager = onNavigation { HotKeyManager(
      config: Config(input: InputConfig(focusFollowsMouse: true)),
      pointerMotionHandler: { invocation in
        DispatchQueue.main.async { received.value.append(invocation) }
      },
      displayPointerRouter: pointerRouter
    ) { _ in } }
    try startHotKeys(manager)
    defer { onNavigation { manager.stop() } }
    let event = try XCTUnwrap(CGEvent(
      mouseEventSource: CGEventSource(stateID: .hidSystemState),
      mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left
    ))
    event.setDoubleValueField(.mouseEventDeltaX, value: 5)
    let startedAt = ProcessInfo.processInfo.systemUptime
    event.post(tap: .cghidEventTap)
    XCTAssertTrue(pumpRunLoop(until: {
      received.value.contains { $0.location == CGPoint(x: destination.x, y: destination.y) && $0.windowID == nil }
    }, timeout: 0.5), "First crossing event did not deliver the destination: \(received.value)")
    print("DEFI_E2E pointer-crossing-delivery-ms=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)")
    XCTAssertEqual(controller.pointerRouter.warpCount, 1)
  }

  func testParkingAvoidsEveryOtherConnectedMonitor() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard snapshot.monitors.count > 1,
      let window = testWindows(in: snapshot).first
    else { throw XCTSkip("Requires two connected monitors and a manageable window") }
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    for monitor in snapshot.monitors {
      for side in [ParkingSide.left, .right] {
        let target = resolveParkingPlacement(
          for: window.frame, ownerFrame: monitor.physicalFrame,
          parkingFrame: monitor.frame,
          allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
          preferredSide: side
        ).frame
        onNavigation { platform.apply(
          [FrameAssignment(windowID: window.id, frame: target)],
          hiddenWindowIDs: [window.id]
        ) }
        XCTAssertTrue(pumpRunLoop(until: { !onNavigation { platform.hasPendingAnimatedFrameWrites } }, timeout: 2))
        pumpRunLoop(for: 0.2)
        let element = try XCTUnwrap(platform.elements[window.id])
        let actual = try XCTUnwrap(platform.frame(of: element))
        XCTAssertEqual(actual.x, target.x, accuracy: 2, onNavigation { platform.frameCoordinatorTrace })
        XCTAssertEqual(actual.y, target.y, accuracy: 2)
        let rect = CGRect(x: actual.x, y: actual.y, width: actual.width, height: actual.height)
        for other in snapshot.monitors where other.id != monitor.id {
          let frame = other.physicalFrame
          let intersection = rect.intersection(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
          XCTAssertTrue(intersection.isNull || intersection.isEmpty,
                        "Parking leaked into \(other.id): \(intersection)")
        }
      }
    }
  }

  func testCornerParkingRepairsDelayedRollback() throws {
    let platform = try makePlatform()
    let snapshot = platform.snapshot(config: Config())
    guard let window = testWindows(in: snapshot).first,
      let monitor = snapshot.monitors.first
    else {
      throw XCTSkip("No manageable desktop window")
    }
    let parked = resolveParkingPlacement(
      for: window.frame,
      ownerFrame: monitor.physicalFrame,
      parkingFrame: monitor.frame,
      allMonitorFrames: snapshot.monitors.map(\.physicalFrame),
      preferredSide: .right
    ).frame
    defer {
      onNavigation { platform.apply([FrameAssignment(windowID: window.id, frame: window.frame)]) }
      pumpRunLoop(for: 0.3)
    }
    onNavigation { platform.apply(
      [FrameAssignment(windowID: window.id, frame: parked)],
      hiddenWindowIDs: [window.id],
    ) }
    pumpRunLoop(for: 0.2)

    // Simulate one delayed application write, without starting a second
    // settlement coordinator that would keep restoring the competing target.
    let element = try XCTUnwrap(platform.elements[window.id])
    var rollback = CGPoint(x: window.frame.x + 40, y: window.frame.y)
    let rollbackValue = try XCTUnwrap(AXValueCreate(.cgPoint, &rollback))
    XCTAssertEqual(AXUIElementSetAttributeValue(
      element, kAXPositionAttribute as CFString, rollbackValue
    ), .success)

    var repaired: Rect?
    XCTAssertTrue(
      pumpRunLoop(
        until: {
          guard onNavigation({ platform.parkingPerformance }).repairs >= 1 else { return false }
          repaired = platform.frame(of: element)
          return repaired.map { abs($0.x - parked.x) <= 2 && abs($0.y - parked.y) <= 2 } == true
        },
        timeout: 1.6
      ),
      "parking repair did not converge before its 1.4 second backstop"
    )
    XCTAssertEqual(repaired?.x ?? 0, parked.x, accuracy: 2)
    XCTAssertEqual(repaired?.y ?? 0, parked.y, accuracy: 2)
    XCTAssertGreaterThanOrEqual(
      onNavigation { platform.parkingPerformance }.repairs,
      1
    )
  }

  private func pumpApplicationEvents(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      if let event = NSApplication.shared.nextEvent(
        matching: .any, until: deadline, inMode: .default, dequeue: true) {
        NSApplication.shared.sendEvent(event)
      }
    }
  }

  private func startHotKeys(_ manager: HotKeyManager) throws {
    try onNavigation { try manager.start() }
    if onNavigation({ manager.bindingError == nil && manager.bindingCount > 0 }),
      !ShortcutRecorderButton.capturesKeyboard {
      XCTAssertTrue(pumpRunLoop(until: {
        onNavigation { manager.isHotKeyCaptureEnabled || manager.bindingError != nil }
      }, timeout: 2), "Carbon hotkey registration did not complete")
      XCTAssertNil(onNavigation { manager.bindingError })
    } else {
      pumpRunLoop(for: 0.05)
    }
  }

  private func pumpRunLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: deadline)
    }
  }

  private func pumpRunLoop(
    until condition: () -> Bool,
    timeout: TimeInterval
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(
        mode: .default,
        before: min(deadline, Date().addingTimeInterval(0.01))
      )
    }
    return condition()
  }

}

/// Desktop tests own AppKit on MainActor; native commands enter the same serial
/// executor as the installed daemon. Never wrap a synchronous desktop snapshot.
@discardableResult
private func onNavigation<T>(_ body: @NavigationActor () throws -> T) rethrows -> T {
  try NavigationActor.shared.queue.sync {
    try NavigationActor.assumeIsolated(body)
  }
}

@MainActor
private final class DesktopValue<Value> {
  var value: Value
  init(_ value: Value) { self.value = value }
}
