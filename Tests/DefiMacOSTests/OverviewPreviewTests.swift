import CoreGraphics
import DefiModel
import Testing
@testable import DefiMacOS

struct OverviewPreviewTests {
  @Test
  func `Capture scheduler never exceeds its bound and preserves order`() async {
    let probe = CaptureProbe()
    let requests = (1...7).map {
      OverviewPreviewRequest(
        windowID: WindowID(rawValue: UInt64($0)),
        expectedAppID: "app",
        width: 100,
        height: 80
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

  @Test
  func `Stale or empty preview results are rejected`() {
    let request = OverviewPreviewRequest(
      windowID: WindowID(rawValue: 1),
      expectedAppID: "app",
      width: 100,
      height: 80
    )
    let result = OverviewPreviewCaptureResult(request: request, image: nil)

    #expect(
      !overviewPreviewResultIsCurrent(
        result,
        generation: 1,
        currentGeneration: 2,
        currentRequest: request,
        currentAppID: "app"
      )
    )
    #expect(
      !overviewPreviewResultIsCurrent(
        result,
        generation: 1,
        currentGeneration: 1,
        currentRequest: request,
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
  func `Progressive blur stays close to the title band`() {
    let fadeHeight = overviewPreviewBlurFadeHeight(imageHeight: 512)
    #expect(fadeHeight >= 120 && fadeHeight <= 145)
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
    let blurred = try #require(progressivelyBlurredOverviewPreview(image))

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
