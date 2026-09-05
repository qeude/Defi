import AppKit
import CoreGraphics
import DefiConfig
import DefiCore
import DefiModel
import Testing
@testable import DefiMacOS

struct OverviewPreviewTests {
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
    #expect(maximum > 0 && maximum <= 2)
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
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10.08, reduceMotion: false) < 0.25)
    let midpoint = overviewPreviewOpacity(startedAt: 10, now: 10.16, reduceMotion: false)
    #expect(midpoint > 0.45 && midpoint < 0.55)
    #expect(overviewPreviewOpacity(startedAt: 10, now: 10.32, reduceMotion: false) == 1)
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
