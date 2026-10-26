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
    func entry(_ id: UInt64, bytes: Int, reducible: Bool, shown: TimeInterval) -> WindowCaptureBudgetEntry {
      WindowCaptureBudgetEntry(id: WindowID(rawValue: id), bytes: bytes, reducible: reducible, shownAt: shown)
    }
    let entries = [
      entry(1, bytes: 40, reducible: true, shown: 30),
      entry(2, bytes: 40, reducible: true, shown: 20),
      entry(3, bytes: 20, reducible: true, shown: 10),
      entry(4, bytes: 40, reducible: true, shown: 5),
      // Older but small enough to fit: still reduced, recency alone decides.
      entry(6, bytes: 3, reducible: true, shown: 1),
      // Already reduced: costs nothing against the cap and is kept.
      entry(7, bytes: 0, reducible: false, shown: 0),
      entry(5, bytes: 11, reducible: false, shown: 0),
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
      let context = try #require(CGContext(data: nil, width: 2_048, height: 2_048, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      return WindowPicture(contents: try #require(context.makeImage()),
        size: CGSize(width: 1_024, height: 1_024), capturedAt: 1, pixelScale: 2)
    }
    let full = try picture()
    let store = WindowCaptureStore(byteLimit: full.byteCost + full.byteCost / 2)
    let old = WindowID(rawValue: 1), recent = WindowID(rawValue: 2)
    func refresh(_ id: WindowID) -> RibbonProxyRefresh {
      RibbonProxyRefresh(id: id, appID: "app", processID: 42, frame: Rect(x: 0, y: 0, width: 1_024, height: 1_024),
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
    #expect(store.byteCount < full.byteCost + full.byteCost / 2)
    store.applyMemoryPressure(.critical)
    #expect(store.count == 0)
  }

  /// A WindowServer-layout capture (BGRA, premultiplied): runs of pixels, like window content.
  private func windowServerPicture(width: Int, height: Int) throws -> WindowPicture {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: space, bitmapInfo: windowPixelsBitmapInfo.rawValue))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt32.self)
    for index in 0..<(width * height) { pixels[index] = 0xFF00_0000 | UInt32(index / 16 & 0x00FF_FFFF) }
    return WindowPicture(contents: try #require(context.makeImage()),
      size: CGSize(width: width / 2, height: height / 2), capturedAt: 3, pixelScale: 2)
  }

  private func bytes(_ image: CGImage?) -> [UInt8] {
    guard let image, let context = CGContext(data: nil, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace!,
      bitmapInfo: windowPixelsBitmapInfo.rawValue) else { return [] }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
      count: image.width * image.height * 4))
  }

  @Test
  func `Reduced picture restores its full pixels, size and colours`() throws {
    var full = try windowServerPicture(width: 2_600, height: 1_400)
    full.appID = "app"; full.processID = 42
    let reduced = try #require(full.reduced())
    #expect(reduced.isReduced && reduced.full != nil)
    let compressed = try #require(reduced.full?.data.count)
    #expect(compressed < full.byteCost)
    let restored = try #require(reduced.restored())
    #expect(!restored.isReduced && restored.buffer != nil)
    #expect(restored.size == full.size && restored.pixelScale == 2 && restored.capturedAt == 3)
    #expect(restored.appID == "app" && restored.processID == 42)
    #expect(restored.image?.colorSpace?.name == CGColorSpace.displayP3)
    #expect(bytes(restored.image) == bytes(full.image))
    // Reducing it again reuses the compressed pixels instead of compressing anew.
    #expect(restored.reduced()?.full?.data == reduced.full?.data)
  }

  @Test
  func `Store restores only the reduced pictures the cap keeps full`() async throws {
    let picture = try windowServerPicture(width: 2_600, height: 1_400)
    let store = WindowCaptureStore(byteLimit: picture.byteCost + picture.byteCost / 2)
    let first = WindowID(rawValue: 1), second = WindowID(rawValue: 2)
    func refresh(_ id: WindowID) -> RibbonProxyRefresh {
      RibbonProxyRefresh(id: id, appID: "app", processID: 42, frame: Rect(x: 0, y: 0, width: 1_300, height: 700),
        distance: 0)
    }
    store.markShown([first], at: 1)
    store.setPicture(picture, for: refresh(first))
    store.markShown([second], at: 2)
    store.setPicture(try windowServerPicture(width: 2_600, height: 1_400), for: refresh(second))
    func settle(_ done: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(30)
      while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    }
    try await settle { store.picture(first)?.isReduced == true && store.picture(first)?.full != nil }
    #expect(store.picture(first)?.isReduced == true)
    // Not the most recent: restoring it would not fit, so it stays reduced.
    store.restore([first])
    try await Task.sleep(for: .milliseconds(200))
    #expect(store.picture(first)?.isReduced == true)
    // Shown again: it is restored, and the other one gives up its full resolution.
    store.markShown([first], at: 3)
    store.restore([first])
    try await settle { store.picture(first)?.isReduced == false && store.picture(second)?.isReduced == true }
    #expect(store.picture(first)?.isReduced == false && store.picture(first)?.capturedAt == 3)
    #expect(store.picture(second)?.isReduced == true)
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
