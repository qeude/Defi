import AppKit
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Testing
import ScreenCaptureKit
@testable import DefiMacOS

struct OverviewPreviewTests {
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

  @MainActor @Test func pressureReserveKeepsOnlyPreferredImagesWithinItsBudget() {
    let cache = OverviewPreviewCache(maximumBytes: 100)
    let ids = (1...3).map { WindowID(rawValue: UInt64($0)) }
    let image = NSImage(size: NSSize(width: 10, height: 10))
    for id in ids {
      cache.store(image, byteCost: 30, for: Window(id: id, appID: "test", title: "Test",
        frame: Rect(x: 0, y: 0, width: 10, height: 10), processID: 42))
    }
    cache.retain([ids[1], ids[2]], maximumBytes: 35)
    #expect(Set(cache.images.keys) == [ids[1]])
    #expect(cache.byteCount == 30)
    cache.removeAll()
    #expect(cache.byteCount == 0)
  }
  @Test func missingOrUnreadyImageDoesNotCancelOtherOpeningSurfaces() {
    let first = WindowID(rawValue: 1), missing = WindowID(rawValue: 2)
    let warming = WindowID(rawValue: 3), unrelated = WindowID(rawValue: 4)
    #expect(overviewReadySurfaceIDs(requested: [first, missing, warming],
      captured: [first, warming, unrelated], displayReady: [first, unrelated]) == [first])
    #expect(overviewReadySurfaceIDs(requested: [missing],
      captured: [first], displayReady: [first]).isEmpty)
  }
  @Test
  func ribbonRejectsARescaledCaptureOfADifferentNativeSize() {
    let native = Rect(x: 2, y: 37, width: 752, height: 902)
    // A configured output of 1504 pixels can still contain a screenshot of a
    // 1508-point source window. Matching output dimensions does not prove fidelity.
    #expect(!overviewSurfaceMatchesNativeSize(source: CGSize(width: 1508, height: 902), native: native))
    #expect(overviewSurfaceMatchesNativeSize(source: CGSize(width: 752, height: 902), native: native))
    #expect(!overviewSurfaceMatchesNativeSize(source: CGSize(width: CGFloat.nan, height: 902), native: native))
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

  @Test
  func ordinaryCaptureFailureDoesNotDisableAuthorization() async {
    let limiter = OverviewCaptureLimiter(limit: 1)
    #expect(await limiter.acquire())
    await limiter.release(error: NSError(domain: "test.transient", code: 1))
    #expect(await limiter.authorizationDeclined == false)
    #expect(await limiter.acquire())
    await limiter.release()
  }
  @Test
  func overlappingBatchesShareCaptureSlotsWithoutRetainingDeliveredImages() async {
    let limiter = OverviewCaptureLimiter(limit: 2)
    let probe = CaptureProbe()
    let delivered = CaptureProbe()
    let requests = (1...8).map { OverviewPreviewRequest(windowID: WindowID(rawValue: UInt64($0)),
      expectedAppID: "test", width: 100, height: 80, blurFadeHeight: 20) }
    let capture: @Sendable (OverviewPreviewRequest) async -> OverviewPreviewCaptureResult = { request in
      await limiter.acquire()
      await probe.begin()
      try? await Task.sleep(for: .milliseconds(5))
      await probe.end()
      await limiter.release()
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }
    let complete: @Sendable (OverviewPreviewCaptureResult) async -> Void = { _ in await delivered.begin() }
    async let first = runOverviewPreviewCaptures(requests, retainResults: false,
      completed: complete, capture: capture)
    async let second = runOverviewPreviewCaptures(requests, retainResults: false,
      completed: complete, capture: capture)
    let results = await (first, second)
    #expect(results.0.isEmpty && results.1.isEmpty)
    #expect(await probe.maximum == 2)
    #expect(await delivered.maximum == requests.count * 2)
  }
  @Test
  func allWorkspacePreviewBatchFitsDecodedMemoryBudget() {
    let requests = (1...100).map { OverviewPreviewRequest(
      windowID: WindowID(rawValue: UInt64($0)), expectedAppID: "test",
      width: 1600, height: 1200, blurFadeHeight: 100) }
    let bounded = boundedOverviewPreviewRequests(requests, maximumBytes: 8 * 1024 * 1024)
    #expect(bounded.count == requests.count)
    #expect(bounded.reduce(0) { $0 + $1.width * $1.height * 4 } <= 8 * 1024 * 1024)
    #expect(bounded[0].width < requests[0].width)
    #expect(bounded.map(\.windowID) == requests.map(\.windowID))
    #expect(boundedOverviewPreviewRequests(requests, maximumBytes: 0).isEmpty)
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

  @Test func surfaceCaptureBudgetIncludesProducerLatestAndDisplayedBuffers() {
    let request = OverviewSurfaceRequest(windowID: WindowID(rawValue: 1),
      appID: "test", processID: 1, width: 2_560, height: 1_600)
    #expect(overviewSurfaceRequestsFit([request]))
    #expect(overviewSurfaceRequestsFit([request, request]))
    #expect(!overviewSurfaceRequestsFit(Array(repeating: request, count: 12)))
    #expect(request.estimatedPoolBytes == 2_560 * 1_600 * 6)
  }

  @MainActor @Test func disabledSurfaceCaptureDoesNotStartStreams() {
    let capture = OverviewSurfaceCapture()
    capture.prepare([], enabled: false)
    #expect(capture.state == "disabled")
    #expect(capture.streamCount == 0)
    #expect(capture.estimatedPoolBytes == 0)
  }

  @Test func previewPixelSizeKeepsCardAspectWhenCapped() {
    let large = overviewPreviewPixelSize(cardWidth: 2_000, cardHeight: 1_040, scale: 2)
    #expect(large.width <= 1_024 && large.height <= 768)
    #expect(abs(Double(large.width) / Double(large.height) - 2_000.0 / 1_040.0) < 0.01)
    let small = overviewPreviewPixelSize(cardWidth: 100, cardHeight: 60, scale: 2)
    #expect(small.width == 200 && small.height == 120)
  }

  @Test func capturesSelectedMonitorOutwardFromSelection() {
    func candidate(_ id: UInt64, monitor: UInt64, x: Double) -> OverviewPreviewCandidate {
      OverviewPreviewCandidate(
        request: OverviewPreviewRequest(windowID: WindowID(rawValue: id), expectedAppID: "test",
          width: 100, height: 80, blurFadeHeight: 20),
        monitorID: MonitorID(rawValue: monitor), centerX: x, centerY: 0)
    }
    let order = overviewPreviewCaptureOrder(
      [candidate(1, monitor: 2, x: 500), candidate(2, monitor: 1, x: 900),
       candidate(3, monitor: 1, x: 500), candidate(4, monitor: 1, x: 100),
       candidate(3, monitor: 1, x: 500), candidate(5, monitor: 2, x: 450)],
      selectedMonitorID: MonitorID(rawValue: 1), anchor: (x: 450, y: 0))
    #expect(order.map(\.windowID.rawValue) == [3, 4, 2, 1, 5])
  }

  @Test func fastPreviewArrivesBeforeSlowCaptureCompletes() async {
    let (stream, continuation) = AsyncStream<Bool>.makeStream()
    let timeout = Task {
      try? await Task.sleep(for: .milliseconds(500))
      continuation.yield(false)
      continuation.finish()
    }
    defer { timeout.cancel() }
    let requests = (1...2).map {
      OverviewPreviewRequest(windowID: WindowID(rawValue: UInt64($0)), expectedAppID: "test",
        width: 100, height: 80, blurFadeHeight: 20)
    }
    let results = await runOverviewPreviewCaptures(requests, completed: { result in
      if result.request == requests[0] {
        continuation.yield(true)
        continuation.finish()
      }
    }) { request in
      if request == requests[1] {
        // The slow capture cannot finish until the fast result has been delivered.
        for await delivered in stream { #expect(delivered); break }
      }
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }
    #expect(results.map(\.request) == requests)
  }

  @Test @MainActor
  func compactPreviewsKeepTwentyFourLargeWindowsWithinTheCacheBudget() throws {
    let context = try #require(CGContext(
      data: nil, width: 1600, height: 1200, bitsPerComponent: 8,
      bytesPerRow: 6400, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let original = try #require(context.makeImage())
    let compact = try #require(compactOverviewPreview(original))
    #expect(compact.width == 512)
    #expect(compact.height == 384)
    let cache = OverviewPreviewCache()
    for id in 1...24 {
      let window = Window(
        id: WindowID(rawValue: UInt64(id)), appID: "test", title: "Test",
        frame: Rect(x: 0, y: 0, width: 1600, height: 1200), processID: 42
      )
      cache.store(
        NSImage(cgImage: compact, size: .zero),
        byteCost: compact.bytesPerRow * compact.height, for: window
      )
    }
    #expect(cache.images.count == 24)
    #expect(cache.byteCount < 32 * 1024 * 1024)
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

  @Test @MainActor
  func rememberedCacheBoundsReplacementsAndPrunesReusedWindowIDs() {
    let cache = OverviewPreviewCache(maximumBytes: 100)
    var window = Window(
      id: WindowID(rawValue: 1), appID: "test.app", title: "Test",
      frame: Rect(x: 0, y: 0, width: 10, height: 10), processID: 42
    )
    let image = NSImage(size: NSSize(width: 10, height: 10))
    cache.store(image, byteCost: 80, for: window)
    cache.store(image, byteCost: 90, for: window)
    #expect(cache.byteCount == 90)
    #expect(cache.images.count == 1)
    window.processID = 43
    #expect(cache.prune(windows: [window.id: window]) == [window.id])
    #expect(cache.byteCount == 0)
    cache.store(image, byteCost: 101, for: window)
    #expect(cache.images.isEmpty)
    cache.store(image, byteCost: 80, for: window)
    cache.removeAll()
    #expect(cache.images.isEmpty)
    #expect(cache.byteCount == 0)
  }

  @Test
  func `Desktop capture schedules without window previews`() {
    #expect(
      overviewCaptureBatchNeeded(
        previewRequestCount: 0,
        hasPendingDesktopCapture: true
      )
    )
    #expect(
      !overviewCaptureBatchNeeded(
        previewRequestCount: 0,
        hasPendingDesktopCapture: false
      )
    )
  }

  @Test
  func `Failed desktop capture remains retryable`() {
    let monitorID = MonitorID(rawValue: 1)
    let existingID = MonitorID(rawValue: 2)

    #expect(
      overviewRecordedDesktopCaptureMonitorIDs(
        existing: [],
        requested: [monitorID],
        captured: []
      ).isEmpty
    )
    #expect(
      overviewRecordedDesktopCaptureMonitorIDs(
        existing: [existingID],
        requested: [monitorID],
        captured: [monitorID]
      ) == [existingID, monitorID]
    )
  }

  @Test
  func `Missing desktop capture schedules an idle retry`() {
    let monitorID = MonitorID(rawValue: 1)

    #expect(
      overviewDesktopCaptureRetryNeeded(
        requested: [monitorID],
        captured: []
      )
    )
    #expect(
      !overviewDesktopCaptureRetryNeeded(
        requested: [monitorID],
        captured: [monitorID]
      )
    )
  }

  @Test("Overview parks windows when captured desktop is unavailable")
  func overviewBackdropFallbackPolicy() {
    #expect(
      overviewUsesWorkspaceParking(
        windowPreviewsEnabled: false,
        screenCaptureAccessGranted: true
      )
    )
    #expect(
      overviewUsesWorkspaceParking(
        windowPreviewsEnabled: true,
        screenCaptureAccessGranted: false
      )
    )
    #expect(
      !overviewUsesWorkspaceParking(
        windowPreviewsEnabled: true,
        screenCaptureAccessGranted: true
      )
    )
  }

  @Test
  func `Capture scheduler never exceeds its bound and preserves order`() async {
    let probe = CaptureProbe()
    let requests = (1...7).map {
      OverviewPreviewRequest(
        windowID: WindowID(rawValue: UInt64($0)),
        expectedAppID: "app",
        width: 100,
        height: 80,
        blurFadeHeight: 40
      )
    }

    let results = await runOverviewPreviewCaptures(requests) { request in
      await probe.begin()
      await Task.yield()
      await probe.end()
      return OverviewPreviewCaptureResult(request: request, image: nil)
    }

    let maximum = await probe.maximum
    #expect(maximum > 0 && maximum <= overviewPreviewMaximumConcurrentCaptures)
    #expect(results.map(\.request) == requests)
  }

  @Test(arguments: [
    (UInt64(2), WindowID(rawValue: 1), "app", false),
    (UInt64(1), WindowID(rawValue: 2), "app", false),
    (UInt64(1), WindowID(rawValue: 1), "other", false),
    (UInt64(1), WindowID(rawValue: 1), "app", true),
  ])
  func previewRequestMatchesCurrentCapture(
    currentGeneration: UInt64, currentWindowID: WindowID,
    currentAppID: String, expected: Bool
  ) {
    let request = OverviewPreviewRequest(
      windowID: WindowID(rawValue: 1), expectedAppID: "app",
      width: 100, height: 80, blurFadeHeight: 40
    )
    let currentRequest = OverviewPreviewRequest(
      windowID: currentWindowID, expectedAppID: currentAppID,
      width: 100, height: 80, blurFadeHeight: 40
    )
    #expect(
      overviewPreviewRequestIsCurrent(
        request, generation: 1, currentGeneration: currentGeneration,
        currentRequest: currentRequest, currentAppID: currentAppID
      ) == expected
    )
  }

  @Test
  func `Preview capture rejects a reused window ID from another app`() {
    #expect(
      overviewPreviewOwnerMatches(
        expectedAppID: "com.example.original",
        capturedAppID: "com.example.original"
      )
    )
    #expect(
      overviewPreviewOwnerMatches(
        expectedAppID: "com.example.original",
        capturedAppID: "com.example.replacement"
      ) == false
    )
    #expect(
      overviewPreviewOwnerMatches(
        expectedAppID: "com.example.original",
        capturedAppID: nil
      ) == false
    )
  }

  @Test
  func `Preview capture remains valid after its card is resized`() {
    let original = OverviewPreviewRequest(
      windowID: WindowID(rawValue: 1),
      expectedAppID: "app",
      width: 800,
      height: 500,
      blurFadeHeight: 80
    )
    let resized = OverviewPreviewRequest(
      windowID: original.windowID,
      expectedAppID: original.expectedAppID,
      width: 1_000,
      height: 500,
      blurFadeHeight: original.blurFadeHeight
    )

    #expect(
      overviewPreviewRequestIsCurrent(
        original,
        generation: 1,
        currentGeneration: 1,
        currentRequest: resized,
        currentAppID: "app"
      )
    )
  }

  @Test
  func `Remembered previews stay inside their memory budget`() {
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    var costs = [first: 6]

    #expect(
      overviewPreviewCacheCanStore(
        windowID: second,
        byteCost: 5,
        currentByteCosts: costs,
        maximumBytes: 10
      ) == false
    )
    #expect(
      overviewPreviewCacheCanStore(
        windowID: first,
        byteCost: 8,
        currentByteCosts: costs,
        maximumBytes: 10
      )
    )
    costs[first] = 8
    #expect(costs.values.reduce(0, +) <= 10)
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

  @Test
  func `Progressive blur keeps a soft tail below the compact title band`() {
    let titleBandHeight = overviewWindowTitleBandHeight(iconSize: 24)
    let fadeHeight = overviewPreviewBlurFadeHeight(
      titleBandHeight: titleBandHeight,
      imageScale: 1,
      imageHeight: 900
    )

    #expect(titleBandHeight == 44)
    #expect(fadeHeight == titleBandHeight + 20)
    #expect(
      overviewTitleScrimAlpha(
        progress: titleBandHeight / fadeHeight,
        opacity: 1
      ) > 0
    )
  }

  @Test
  func `Overview title row is left aligned and vertically centered`() {
    let card = CGRect(x: 100, y: 50, width: 400, height: 200)
    let blurHeight = overviewWindowTitleBandHeight(iconSize: 20)
    let layout = overviewWindowTitleLayout(
      cardFrame: card,
      iconSize: 20,
      titleSize: CGSize(width: 100, height: 16),
      blurHeight: blurHeight
    )

    #expect(layout.iconFrame.midY == layout.titleFrame.midY)
    #expect(layout.iconFrame.minX == card.minX + 10)
    #expect(layout.iconFrame.minY == card.minY + 10)
    #expect(layout.titleFrame.minX - layout.iconFrame.maxX == 8)
    let topPadding = layout.titleFrame.minY - card.minY
    let bottomPadding = card.minY + blurHeight - layout.titleFrame.maxY
    #expect(abs(topPadding - bottomPadding) < 0.001)
  }

  @Test
  func `Title scrim has a soft transparent tail`() {
    #expect(overviewTitleScrimAlpha(progress: 0, opacity: 1) == 0.48)
    #expect(overviewTitleScrimAlpha(progress: 0.75, opacity: 1) < 0.04)
    #expect(overviewTitleScrimAlpha(progress: 0.97, opacity: 1) < 0.001)
    #expect(overviewTitleScrimAlpha(progress: 1, opacity: 1) == 0)
  }

  @Test
  func `Progressive blur preserves the captured image dimensions`() throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = try #require(
      CGContext(
        data: nil,
        width: 64,
        height: 64,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo
      )
    )
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
    let image = try #require(context.makeImage())
    let blurred = try #require(
      progressivelyBlurredOverviewPreview(image, fadeHeight: 24)
    )

    #expect(blurred.width == image.width)
    #expect(blurred.height == image.height)
  }
}

private actor CaptureProbe {
  private var current = 0
  private(set) var maximum = 0

  func begin() {
    current += 1
    maximum = max(maximum, current)
  }

  func end() {
    current -= 1
  }
}
