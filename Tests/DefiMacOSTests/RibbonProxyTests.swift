import CoreGraphics
import DefiConfig
import QuartzCore
import DefiModel
import Testing
@testable import DefiMacOS

struct RibbonProxyTests {
  @Test func landingWaitsForEveryVisibleTarget() {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let targets = [a: Rect(x: 10, y: 40, width: 800, height: 900),
      b: Rect(x: 830, y: 40, width: 600, height: 900)]
    var native = [a: Rect(x: 11, y: 41, width: 800, height: 900)]
    #expect(!ribbonProxyLanded(native: native, targets: targets))
    native[b] = Rect(x: 900, y: 40, width: 600, height: 900)
    #expect(!ribbonProxyLanded(native: native, targets: targets))
    native[b] = Rect(x: 832, y: 40, width: 600, height: 900)
    #expect(ribbonProxyLanded(native: native, targets: targets))
    #expect(ribbonProxyLanded(native: [:], targets: [:]))
    // A terminal snapped 4 px lower on its cell grid has still landed.
    #expect(ribbonProxyLanded(native: [a: Rect(x: 10, y: 44, width: 800, height: 896)],
      targets: [a: targets[a]!]))
    #expect(!ribbonProxyLanded(native: [a: Rect(x: 14, y: 40, width: 800, height: 900)],
      targets: [a: targets[a]!]))
  }

  @Test func landingStartsWhenTheRibbonVisiblyStops() {
    // A column step stops visibly about 0.31 s in, a tiny nudge sooner, never past settling.
    #expect(abs(ribbonProxyVisualStop(travel: 1_300) - 0.31) < 0.02)
    #expect(ribbonProxyVisualStop(travel: 2) == 0.12)
    #expect(ribbonProxyVisualStop(travel: 1_000_000) == ribbonProxySpringDuration)
  }

  @Test func resizedWindowInvalidatesItsPicture() {
    let frame = Rect(x: 0, y: 0, width: 800, height: 600)
    #expect(ribbonProxyPictureMatches(captured: CGSize(width: 801, height: 599), native: frame))
    #expect(!ribbonProxyPictureMatches(captured: CGSize(width: 700, height: 600), native: frame))
  }

  @Test func capturesOrderByRibbonDistanceFromTheViewport() {
    let viewport = Rect(x: 0, y: 0, width: 1000, height: 800)
    #expect(ribbonProxyDistance(Rect(x: 900, y: 0, width: 400, height: 800), viewport) == 0)
    #expect(ribbonProxyDistance(Rect(x: 1200, y: 0, width: 400, height: 800), viewport) == 200)
    #expect(ribbonProxyDistance(Rect(x: -700, y: 0, width: 400, height: 800), viewport) == 300)
  }

  @Test func enteringWindowTravelsWithTheSharedNavigationMotion() {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let plan = windowProxyMotion(
      ribbonTargets: [a: Rect(x: -800, y: 40, width: 1000, height: 900),
        b: Rect(x: 220, y: 40, width: 1000, height: 900)],
      otherTargets: [:],
      previousLogical: [a: Rect(x: 200, y: 40, width: 1000, height: 900)],
      // Native clamping made the visible window 20 px taller and lower.
      observed: [a: Rect(x: 200, y: 50, width: 1000, height: 920),
        b: Rect(x: 2559, y: 50, width: 1000, height: 920)])
    let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
    #expect(byID[a]?.from == Rect(x: 200, y: 50, width: 1000, height: 920))
    #expect(byID[a]?.to == Rect(x: -800, y: 50, width: 1000, height: 920))
    // Parked natively at the edge, it enters 1000 px further right than its target.
    #expect(byID[b]?.from == Rect(x: 1220, y: 40, width: 1000, height: 920))
    #expect(byID[b]?.to == Rect(x: 220, y: 40, width: 1000, height: 920))
  }

  @Test func learnedAppPlacementPutsThePictureExactlyOnTheWindow() {
    let a = WindowID(rawValue: 1)
    let target = Rect(x: 220, y: 40, width: 1000, height: 900)
    // Last landing at this size, the app sat 4 pt lower and 6 pt shorter on its cell grid.
    let settle = RibbonProxySettle(target: target, native: Rect(x: 220, y: 44, width: 1000, height: 894))
    #expect(RibbonProxySettle(target: target, native: target) == nil)
    let plan = windowProxyMotion(ribbonTargets: [a: target], otherTargets: [:],
      previousLogical: [a: Rect(x: 1220, y: 40, width: 1000, height: 900)],
      observed: [a: Rect(x: 1220, y: 44, width: 1000, height: 894)], settled: [a: settle!])
    #expect(plan.first?.from == Rect(x: 1220, y: 44, width: 1000, height: 894))
    #expect(plan.first?.to == Rect(x: 220, y: 44, width: 1000, height: 894))
    // Another size: the learned offset no longer applies to the target.
    let wider = windowProxyMotion(ribbonTargets: [a: Rect(x: 220, y: 40, width: 1200, height: 900)],
      otherTargets: [:], previousLogical: [a: target], observed: [a: target], settled: [a: settle!])
    #expect(wider.first?.to == Rect(x: 220, y: 40, width: 1200, height: 900))
  }

  @Test func verticalSwitchInferredFromLeavingWindowsMovesThemTogether() {
    let leaving = WindowID(rawValue: 1), arriving = WindowID(rawValue: 2)
    let plan = windowProxyMotion(
      ribbonTargets: [arriving: Rect(x: 10, y: 40, width: 800, height: 900)],
      otherTargets: [leaving: Rect(x: 10, y: -1400, width: 800, height: 900)],
      previousLogical: [leaving: Rect(x: 10, y: 40, width: 800, height: 900)],
      observed: [leaving: Rect(x: 10, y: 40, width: 800, height: 900),
        arriving: Rect(x: 2559, y: 40, width: 800, height: 900)])
    let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
    #expect(byID[leaving]?.to.y == -1400)
    #expect(byID[arriving]?.from.y == 1480)
    #expect(byID[arriving]?.to.y == 40)
  }

  @Test func retargetKeepsTheSpringVelocity() {
    let from = CGPoint(x: 0, y: 0), to = CGPoint(x: 1000, y: 0)
    #expect(ribbonProxySpringVelocity(from: from, to: to, elapsed: 0) == .zero)
    let moving = ribbonProxySpringVelocity(from: from, to: to, elapsed: 0.05)
    #expect(moving.x > 5_000 && moving.y == 0)
    #expect(ribbonProxySpringVelocity(from: from, to: to, elapsed: 0.6).x < 50)
  }

  @Test func macOSActivatedSwitchSlidesLeavingWindowsOffVertically() {
    let leaving = WindowID(rawValue: 1), arriving = WindowID(rawValue: 2)
    let plan = windowProxyMotion(
      ribbonTargets: [arriving: Rect(x: 10, y: 40, width: 800, height: 900)],
      // Natively the leaving window parks on the right edge.
      otherTargets: [leaving: Rect(x: 2559, y: 40, width: 800, height: 900)],
      previousLogical: [leaving: Rect(x: 10, y: 40, width: 800, height: 900)],
      observed: [leaving: Rect(x: 10, y: 40, width: 800, height: 900),
        arriving: Rect(x: 2559, y: 40, width: 800, height: 900)],
      verticalShift: 1440)
    let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
    #expect(byID[leaving]?.to == Rect(x: 10, y: 1480, width: 800, height: 900))
    #expect(byID[arriving]?.from == Rect(x: 10, y: -1400, width: 800, height: 900))
    #expect(byID[arriving]?.to == Rect(x: 10, y: 40, width: 800, height: 900))
  }

  @Test func leavingWindowWithoutRibbonHistorySlidesVerticallyIntoAnEmptyWorkspace() {
    let leaving = WindowID(rawValue: 1)
    let plan = windowProxyMotion(
      ribbonTargets: [:],
      // Natively it parks off the left edge; the overlay must still slide it with the switch.
      otherTargets: [leaving: Rect(x: -745, y: 40, width: 746, height: 898)],
      previousLogical: [:],
      observed: [leaving: Rect(x: 4, y: 40, width: 746, height: 898)],
      verticalShift: -982)
    #expect(plan.first?.from == Rect(x: 4, y: 40, width: 746, height: 898))
    #expect(plan.first?.to == Rect(x: 4, y: -942, width: 746, height: 898))
  }

  @Test func parkedEdgeStripDoesNotCountAsOnScreen() {
    let bounds = CGRect(x: 0, y: 0, width: 1512, height: 940)
    #expect(!ribbonProxyShows(CGRect(x: 1511, y: 43, width: 1496, height: 898), in: bounds))
    #expect(!ribbonProxyShows(CGRect(x: 8, y: -935, width: 1496, height: 898), in: bounds))
    #expect(ribbonProxyShows(CGRect(x: 8, y: -888, width: 1496, height: 898), in: bounds))
    #expect(ribbonProxyShows(CGRect(x: 1215, y: 47, width: 489, height: 898), in: bounds))
  }

  @Test func overlayLayersUseABottomLeftOrigin() {
    let area = Rect(x: 0, y: 34, width: 2560, height: 1368)
    // A window just under the menu bar sits at the top of the overlay.
    #expect(ribbonProxyLocal(Rect(x: 4, y: 34, width: 1000, height: 1360), in: area)
      == CGRect(x: 4, y: 8, width: 1000, height: 1360))
    // Moving the pointer down lowers its overlay y.
    #expect(ribbonProxyLocal(CGPoint(x: 10, y: 100), in: area).y
      > ribbonProxyLocal(CGPoint(x: 10, y: 400), in: area).y)
  }

  @Test func stackingTakesTheLayoutHeightInsteadOfTheNativeOne() {
    let stacked = WindowID(rawValue: 1)
    let plan = windowProxyMotion(
      ribbonTargets: [stacked: Rect(x: 10, y: 720, width: 800, height: 674)],
      otherTargets: [:],
      previousLogical: [stacked: Rect(x: 10, y: 34, width: 800, height: 1360)],
      observed: [stacked: Rect(x: 10, y: 34, width: 800, height: 1360)])
    #expect(plan.first?.from == Rect(x: 10, y: 34, width: 800, height: 1360))
    #expect(plan.first?.to == Rect(x: 10, y: 720, width: 800, height: 674))
  }

  @Test func aDroppedWindowLandsOnItsSlotNotWhereItWasReleased() {
    let dropped = WindowID(rawValue: 1)
    let plan = windowProxyMotion(
      ribbonTargets: [dropped: Rect(x: 4, y: 34, width: 1270, height: 1360)],
      otherTargets: [:],
      previousLogical: [dropped: Rect(x: 4, y: 34, width: 1270, height: 1360)],
      observed: [dropped: Rect(x: 601, y: 295, width: 1270, height: 1360)])
    #expect(plan.first?.to == Rect(x: 4, y: 34, width: 1270, height: 1360))
  }

  @Test func theEdgeColourIsThePictureBorderColour() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    let image = try #require(context.makeImage())
    let edge = try #require(ribbonProxyEdgeColor(image)?.components)
    #expect(edge[2] > 0.9 && edge[0] < 0.1)
  }

  @Test func theCardRingHugsTheWindowLikeTheNativeRing() throws {
    let layer = CALayer(), ring = CALayer()
    ring.name = "border"; ring.borderWidth = 4
    layer.addSublayer(ring)
    layer.setValue(16.0, forKey: "defiWindowRadius")
    let frames = ribbonProxySublayerFrames(layer, size: CGSize(width: 800, height: 600),
      borderStyle: WindowBorderStyle(config: BordersConfig(placement: "outside")))
    #expect(frames.first?.1 == CGRect(x: -4, y: -4, width: 808, height: 608))
    #expect(ring.cornerRadius == 20)
  }

  @Test func theRightAndBottomBordersWeighTheSame() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 2))
    let image = try #require(context.makeImage())
    let edge = try #require(ribbonProxyEdgeColor(image)?.components)
    #expect(abs(edge[0] - edge[2]) < 0.1)
  }
}

