import AppKit
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Testing
import ScreenCaptureKit
@testable import DefiMacOS

struct OverviewPreviewTests {
  @MainActor @Test func emptyWorkspaceClosingZoomsWallpaperToFullScreen() throws {
    let screen = try #require(NSScreen.main)
    let workspaceID = WorkspaceID(rawValue: "empty")
    let projection = OverviewProjection(monitorID: MonitorID(rawValue: 1), workspaces: [
      OverviewWorkspaceProjection(workspaceID: workspaceID,
        frame: Rect(x: 100, y: 80, width: 320, height: 200), windows: []),
    ])
    let wallpaper = NSImage(size: NSSize(width: 16, height: 10), flipped: false) { rect in
      NSColor.systemBlue.setFill(); rect.fill(); return true
    }
    #expect(OverviewPreviewClosingScene(projection: projection, workspaceID: workspaceID,
      screen: screen, previews: [:], targets: [], windows: [:]) == nil)
    let scene = try #require(OverviewPreviewClosingScene(projection: projection,
      workspaceID: workspaceID, screen: screen, previews: [:], wallpaper: wallpaper,
      targets: [], windows: [:]))
    let item = try #require(scene.layer.sublayers?.first)
    #expect(item.frame == CGRect(x: 100, y: 80, width: 320, height: 200))
    scene.animate(duration: 0.22)
    #expect(abs(item.frame.width - scene.layer.bounds.width) < 0.5)
    #expect(abs(item.frame.height - scene.layer.bounds.height) < 0.5)
    #expect(item.frame.origin == .zero)
    #expect(item.cornerRadius == 0)
  }

  @MainActor @Test func pressureRecoveryRequestsPreloadingWithoutAnotherOpening() {
    var preparations = 0
    let controller = OverviewController(focusWindow: { _, _, _, _ in },
      focusWorkspace: { _, _ in }, drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, idlePreparationRequested: { preparations += 1 },
      notificationCenter: NotificationCenter(), commitScrollOffsets: { _ in })
    controller.handleMemoryPressure(.normal)
    #expect(preparations == 0)
    controller.handleMemoryPressure(.warning)
    controller.handleMemoryPressure(.critical)
    controller.handleMemoryPressure(.normal)
    #expect(preparations == 1)
    controller.handleMemoryPressure(.normal)
    #expect(preparations == 1)
  }

  @Test
  func deniedCaptureStopsAllQueuedAndFutureAttempts() async {
    let limiter = OverviewCaptureLimiter(limit: 1)
    #expect(await limiter.acquire())
    let queued = Task { await limiter.acquire() }
    for _ in 0..<1_000 {
      if await limiter.waitingCount == 1 { break }
      await Task.yield()
    }
    #expect(await limiter.waitingCount == 1)
    await limiter.release(error: NSError(domain: SCStreamErrorDomain, code: -3801))
    #expect(await queued.value == false)
    #expect(await limiter.authorizationDeclined)
    #expect(await limiter.acquire() == false)
  }

  @Test
  func cancelledWaiterFinishesWhileNativeCaptureIsStillPending() async {
    let limiter = OverviewCaptureLimiter(limit: 1)
    #expect(await limiter.acquire())
    let queued = Task { await limiter.acquire() }
    for _ in 0..<1_000 {
      if await limiter.waitingCount == 1 { break }
      await Task.yield()
    }
    #expect(await limiter.waitingCount == 1)
    queued.cancel()
    #expect(await queued.value == false)
    await limiter.release()
    #expect(await limiter.acquire())
    await limiter.release()
  }

  @MainActor @Test
  func hungNativeCaptureFailsAtDeadlineInsteadOfHoldingTheSlot() async throws {
    await #expect(throws: OverviewCaptureTimeoutError.self) {
      try await withOverviewCaptureTimeout(seconds: 0.05) {
        try await Task.sleep(for: .seconds(60))
        return 1
      }
    }
    let value = try await withOverviewCaptureTimeout(seconds: 5) { 7 }
    #expect(value == 7)
  }

  @MainActor @Test
  func timedOutCaptureReleasesTheLimiterSlotToQueuedCapture() async {
    let limiter = OverviewCaptureLimiter(limit: 1)
    #expect(await limiter.acquire())
    let queued = Task { await limiter.acquire() }
    for _ in 0..<1_000 {
      if await limiter.waitingCount == 1 { break }
      await Task.yield()
    }
    do {
      _ = try await withOverviewCaptureTimeout(seconds: 0.05) {
        try await Task.sleep(for: .seconds(60))
        return 1
      }
    } catch {
      await limiter.release(error: error as NSError)
    }
    #expect(await queued.value)
    #expect(await limiter.authorizationDeclined == false)
    await limiter.release()
  }

  @Test
  func ordinaryCaptureFailureDoesNotDisableAuthorization() async {
    let limiter = OverviewCaptureLimiter(limit: 1)
    #expect(await limiter.acquire())
    await limiter.release(error: NSError(domain: "test.transient", code: 1))
    #expect(await limiter.authorizationDeclined == false)
    #expect(await limiter.acquire())
    await limiter.release()
  }
  @MainActor @Test func titleRasterCacheReusesLabelsAndBoundsMemory() throws {
    let cache = OverviewTitleCache(maximumBytes: 12_000)
    let id = WindowID(rawValue: 1)
    let label = try #require(cache.label(for: id, text: "Finder", fontSize: 13,
      maximumWidth: 200, scale: 2))
    for _ in 0..<120 {
      let repeated = try #require(cache.label(for: id, text: "Finder", fontSize: 13,
        maximumWidth: 200, scale: 2))
      #expect(repeated.image === label.image)
    }
    #expect(cache.rasterizationCount == 1)
    let changed = try #require(cache.label(for: id, text: "Downloads", fontSize: 13,
      maximumWidth: 200, scale: 2))
    #expect(changed.image !== label.image)
    #expect(cache.rasterizationCount == 2)
    for value in 2..<50 {
      _ = cache.label(for: WindowID(rawValue: UInt64(value)), text: "Downloads",
        fontSize: 13, maximumWidth: 200, scale: 2)
      #expect(cache.byteCount <= 12_000)
    }
    cache.prune(windowIDs: [])
    #expect(cache.byteCount == 0)
  }

  @Test @MainActor
  func unchangedOverviewPresentationDoesNotRequestAnotherDraw() {
    let controller = OverviewController(
      focusWindow: { _, _, _, _ in }, focusWorkspace: { _, _ in },
      drop: { _, _, _, _, _ in }, activateMonitor: { _ in },
      openStateChanged: { _ in }, commitScrollOffsets: { _ in }
    )
    let monitorID = MonitorID(rawValue: 1)
    let view = OverviewView(monitorID: monitorID, delegate: controller)
    let snapshot = OverviewSnapshot(monitors: [], monitorFrames: [:], windows: [:])
    let projection = OverviewProjection(monitorID: monitorID, workspaces: [])
    func update(radius: Double) -> Bool {
      view.update(
        snapshot: snapshot, projection: projection, selection: nil, drag: nil,
        borderStyle: WindowBorderStyle(config: BordersConfig()),
        windowCornerRadius: radius, previews: [:], previewOpacities: [:]
      )
    }
    #expect(update(radius: 12))
    #expect(update(radius: 12) == false)
    #expect(update(radius: 14))
  }

  @Test("Without previews or Screen Recording the Overview parks windows; permission is requested once")
  func overviewDegradesWithoutCapturePermission() {
    #expect(overviewUsesWorkspaceParking(windowPreviewsEnabled: false, screenCaptureAccessGranted: true))
    #expect(overviewUsesWorkspaceParking(windowPreviewsEnabled: true, screenCaptureAccessGranted: false))
    #expect(!overviewUsesWorkspaceParking(windowPreviewsEnabled: true, screenCaptureAccessGranted: true))
    #expect(overviewShouldRequestCapturePermission(screenCaptureAccessGranted: false, hasRequestedPermission: false))
    #expect(!overviewShouldRequestCapturePermission(screenCaptureAccessGranted: false, hasRequestedPermission: true))
    #expect(!overviewShouldRequestCapturePermission(screenCaptureAccessGranted: true, hasRequestedPermission: false))
  }

  @Test
  func `Capture budget keeps recent windows sharp, reduces older ones, then drops`() {
    func entry(_ id: UInt64, bytes: Int, reduced: Int?, shown: TimeInterval) -> WindowCaptureBudgetEntry {
      WindowCaptureBudgetEntry(id: WindowID(rawValue: id), bytes: bytes, reducedBytes: reduced, shownAt: shown)
    }
    let entries = [
      entry(1, bytes: 40, reduced: 4, shown: 30),
      entry(2, bytes: 40, reduced: 4, shown: 20),
      entry(3, bytes: 20, reduced: 2, shown: 10),
      entry(4, bytes: 40, reduced: 4, shown: 5),
      // Older but small enough to fit: still reduced, recency alone decides.
      entry(6, bytes: 3, reduced: 1, shown: 1),
      entry(5, bytes: 9, reduced: nil, shown: 0),
    ]
    let plan = windowCaptureBudgetPlan(entries, limit: 90)
    #expect(plan.reduce == [3, 4, 6].map { WindowID(rawValue: $0) })
    #expect(plan.drop == [WindowID(rawValue: 5)])
    let roomy = windowCaptureBudgetPlan(entries, limit: 1_000)
    #expect(roomy.reduce.isEmpty && roomy.drop.isEmpty)
  }

  @Test
  func `Store reduces the least recently shown picture, then releases all under pressure`() async throws {
    func picture() throws -> WindowPicture {
      let context = try #require(CGContext(data: nil, width: 1_024, height: 1_024, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      return WindowPicture(contents: try #require(context.makeImage()),
        size: CGSize(width: 512, height: 512), capturedAt: 1, pixelScale: 2)
    }
    let full = try picture()
    let store = WindowCaptureStore(byteLimit: full.byteCost + full.byteCost / 2)
    let old = WindowID(rawValue: 1), recent = WindowID(rawValue: 2)
    func refresh(_ id: WindowID) -> RibbonProxyRefresh {
      RibbonProxyRefresh(id: id, appID: "app", processID: 42, frame: Rect(x: 0, y: 0, width: 512, height: 512),
        distance: 0)
    }
    store.markShown([old])
    store.setPicture(full, for: refresh(old))
    try await Task.sleep(for: .milliseconds(5))
    store.markShown([recent])
    store.setPicture(try picture(), for: refresh(recent))
    // Reduction runs on a utility queue, which parallel tests can starve for seconds.
    let deadline = Date().addingTimeInterval(30)
    while store.reducedCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.picture(old)?.isReduced == true)
    #expect(store.picture(recent)?.isReduced == false)
    #expect(store.byteCount <= full.byteCost + full.byteCost / 2)
    store.applyMemoryPressure(.critical)
    #expect(store.count == 0)
  }

  @Test
  func `Reduced picture keeps its point size for every consumer`() throws {
    let context = try #require(CGContext(data: nil, width: 2_048, height: 1_024, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    var picture = WindowPicture(contents: image, size: CGSize(width: 1_024, height: 512),
      capturedAt: 7, pixelScale: 2)
    picture.appID = "app"; picture.processID = 42
    let reducedBytes = try #require(picture.reducedByteCost)
    let reduced = try #require(picture.reduced())
    #expect(reduced.isReduced && reduced.reducedByteCost == nil)
    #expect(reduced.size == picture.size && reduced.capturedAt == 7)
    #expect(reduced.pixelScale == 0.5 && reduced.byteCost == reducedBytes)
    #expect(reduced.appID == "app" && reduced.processID == 42)
    #expect(ribbonProxyPictureMatches(captured: reduced.size, native: Rect(x: 0, y: 0, width: 1_024, height: 512)))
  }

  @Test
  func `Blurred title band copy is small and keeps the picture aspect`() throws {
    let context = try #require(CGContext(data: nil, width: 1_600, height: 1_000, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 800, height: 1_000))
    let image = try #require(context.makeImage())
    let blurred = try #require(overviewBlurredPreview(image))
    #expect(blurred.width == 256 && blurred.height == 160)
  }

  @Test
  func `Preview reveal fades in and respects reduced motion`() {
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10, reduceMotion: false) == 0)
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10.1, reduceMotion: false) < 0.25)
    let midpoint = overviewPreviewOpacity(startedAt: 10, now: 10.225, reduceMotion: false)
    #expect(midpoint > 0.45 && midpoint < 0.55)
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10.45, reduceMotion: false) == 1)
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10, reduceMotion: true) == 1)
  }

}
