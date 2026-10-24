import CoreGraphics
import DefiConfig
import DefiCore
import QuartzCore
import DefiModel
import Testing
@testable import DefiMacOS

struct RibbonProxyTests {
  @Test func landingWaitsForEveryVisibleTarget() {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let targets = [a: Rect(x: 10, y: 40, width: 800, height: 900),
      b: Rect(x: 830, y: 40, width: 600, height: 900)]
    var native = [a: Rect(x: 11, y: 41, width: 800, height: 900),
      b: Rect(x: 900, y: 40, width: 600, height: 900)]
    #expect(!ribbonProxyLanded(native: native, targets: targets))
    native[b] = Rect(x: 832, y: 40, width: 600, height: 900)
    #expect(ribbonProxyLanded(native: native, targets: targets))
    #expect(ribbonProxyLanded(native: [:], targets: [:]))
    // A window closed mid-motion is gone from the WindowServer: nothing holds the landing.
    #expect(ribbonProxyLanded(native: [a: native[a]!], targets: targets))
    // A terminal snapped 4 px lower on its cell grid has still landed.
    #expect(ribbonProxyLanded(native: [a: Rect(x: 10, y: 44, width: 800, height: 896)],
      targets: [a: targets[a]!]))
    #expect(!ribbonProxyLanded(native: [a: Rect(x: 14, y: 40, width: 800, height: 900)],
      targets: [a: targets[a]!]))
  }

  @Test func landingDoesNotWaitForAWindowAnchoredInASliver() {
    let finder = WindowID(rawValue: 1), xcode = WindowID(rawValue: 2)
    let display = Rect(x: 0, y: 0, width: 2560, height: 1440)
    // An offscreen column's anchor shows one point; macOS keeps Xcode 20 pt higher.
    let targets = [finder: Rect(x: 1702, y: 34, width: 740, height: 1359),
      xcode: Rect(x: -1269, y: 1365, width: 1270, height: 1359)]
    let awaited = ribbonProxyLandingTargets(targets, area: display)
    #expect(awaited == [finder: Rect(x: 1702, y: 34, width: 740, height: 1359)])
    #expect(ribbonProxyLanded(native: [finder: Rect(x: 1702, y: 34, width: 740, height: 1359),
      xcode: Rect(x: -1269, y: 1345, width: 1270, height: 1359)], targets: awaited))
  }

  @Test func aWindowMovingToASliverAnchorMustLeaveBeforeTheOverlayLifts() {
    let display = Rect(x: 0, y: 0, width: 2560, height: 1440)
    let visible = Rect(x: 400, y: 34, width: 1270, height: 1359)
    #expect(ribbonProxyLeaves(from: visible, to: Rect(x: -1269, y: 1365, width: 1270, height: 1359), area: display))
    #expect(!ribbonProxyLeaves(from: visible, to: Rect(x: 1000, y: 34, width: 1270, height: 1359), area: display))
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

  @Test func onlyTheDisplayALayoutMovesPresentsWithSeveralDisplays() {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2), c = WindowID(rawValue: 3)
    let left = WindowProxyMonitor(viewport: Rect(x: 0, y: 0, width: 1000, height: 800), windowIDs: [a, b])
    let frame = Rect(x: 0, y: 0, width: 500, height: 800)
    let moved = Rect(x: -400, y: 0, width: 500, height: 800)
    func moves(_ monitor: WindowProxyMonitor, displays: Int = 2, targets: [WindowID: Rect],
      previous: [WindowID: Rect], opened: Set<WindowID> = [], dropped: WindowID? = nil) -> Bool {
      windowProxyDisplayMoves(monitor, displayCount: displays, ribbonTargets: targets,
        previousRibbonFrames: previous, opened: opened, dropped: dropped)
    }
    #expect(!moves(left, targets: [a: frame], previous: [a: frame, c: frame]))
    #expect(moves(left, displays: 1, targets: [a: frame], previous: [a: frame]))
    #expect(moves(left, targets: [a: moved], previous: [a: frame]))
    #expect(moves(left, targets: [a: frame, b: frame], previous: [a: frame]))
    // A window leaving the ribbon (closed, sent away) reflows the display.
    #expect(moves(left, targets: [a: frame], previous: [a: frame, b: frame]))
    #expect(moves(left, targets: [a: frame], previous: [a: frame], opened: [b]))
    #expect(!moves(left, targets: [a: frame], previous: [a: frame], opened: [c], dropped: c))
    #expect(moves(left, targets: [a: frame], previous: [a: frame], dropped: a))
    // A window this layout skips (a focus change pending elsewhere) stays where it is.
    #expect(!windowProxyDisplayMoves(left, displayCount: 2, ribbonTargets: [:],
      previousRibbonFrames: [a: frame], opened: [], dropped: nil, skipped: [a]))
    var switched = left
    switched.workspaceShift = -800
    #expect(moves(switched, targets: [:], previous: [:]))
  }

  @Test func aLayoutLimitedToOneDisplayLeavesTheOtherStillOnTheNextFullLayout() {
    let a = WindowID(rawValue: 1), b = WindowID(rawValue: 2)
    let slot = Rect(x: 0, y: 40, width: 500, height: 800)
    let next = Rect(x: -400, y: 40, width: 500, height: 800)
    let side = Rect(x: 2564, y: -932, width: 488, height: 915)
    let external = WindowProxyMonitor(viewport: Rect(x: 0, y: 0, width: 2560, height: 1440), windowIDs: [a])
    let builtIn = WindowProxyMonitor(viewport: Rect(x: 2560, y: -949, width: 1512, height: 949),
      windowIDs: [b], laidOut: false)
    let history = windowProxyRibbonHistory([FrameAssignment(windowID: a, frame: next)],
      previous: [a: slot, b: side], monitors: [external, builtIn])
    #expect(history == [a: next, b: side])
    let laidOut = WindowProxyMonitor(viewport: builtIn.viewport, windowIDs: [b])
    #expect(!windowProxyDisplayMoves(laidOut, displayCount: 2, ribbonTargets: [a: next, b: side],
      previousRibbonFrames: history, opened: [], dropped: nil))
    // Laid out without ribbon frames (an emptied workspace), its windows have left.
    #expect(windowProxyRibbonHistory([FrameAssignment(windowID: a, frame: next)],
      previous: [a: slot, b: side], monitors: [external, laidOut]) == [a: next])
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

  @Test func aDroppedWindowSettlesWhereItsNeighboursSettleOnANotchedDisplay() {
    let dropped = WindowID(rawValue: 1), b = WindowID(rawValue: 2), c = WindowID(rawValue: 3)
    // The display clamps every 941-pt window 13 pt above its ribbon place.
    let plan = windowProxyMotion(
      ribbonTargets: [dropped: Rect(x: 3564, y: -932, width: 488, height: 915),
        b: Rect(x: 2564, y: -932, width: 488, height: 915), c: Rect(x: 3064, y: -932, width: 488, height: 915)],
      otherTargets: [:],
      previousLogical: [dropped: Rect(x: 3064, y: -932, width: 489, height: 915),
        b: Rect(x: 2564, y: -932, width: 489, height: 915), c: Rect(x: 3564, y: -932, width: 489, height: 915)],
      observed: [dropped: Rect(x: 3300, y: -790, width: 489, height: 941),
        b: Rect(x: 2564, y: -945, width: 489, height: 941), c: Rect(x: 3564, y: -945, width: 489, height: 941)],
      dropped: dropped)
    let byID = Dictionary(uniqueKeysWithValues: plan.map { ($0.id, $0) })
    #expect(byID[dropped]?.to == Rect(x: 3564, y: -945, width: 488, height: 941))
    #expect(byID[c]?.to == Rect(x: 3064, y: -945, width: 488, height: 941))
  }

  @Test func aLearnedPlacementSurvivesAColumnReflowedOnePointNarrower() {
    let dropped = WindowID(rawValue: 1)
    let settle = RibbonProxySettle(target: Rect(x: 3064, y: -932, width: 489, height: 915),
      native: Rect(x: 3064, y: -945, width: 489, height: 941))
    let plan = windowProxyMotion(
      ribbonTargets: [dropped: Rect(x: 3564, y: -932, width: 488, height: 915)], otherTargets: [:],
      previousLogical: [dropped: Rect(x: 3064, y: -932, width: 489, height: 915)],
      observed: [dropped: Rect(x: 3300, y: -790, width: 489, height: 941)],
      settled: [dropped: settle!], dropped: dropped)
    #expect(plan.first?.to == Rect(x: 3564, y: -945, width: 488, height: 941))
  }

  @Test func theEdgeColourWeighsTheRightAndBottomBordersEqually() throws {
    func edge(blueBottomRows: Int) throws -> [CGFloat] {
      let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
      let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
      context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: 100, height: blueBottomRows))
      let image = try #require(context.makeImage())
      return try #require(ribbonProxyEdgeColor(image)?.components)
    }
    let blue = try edge(blueBottomRows: 100)
    #expect(blue[2] > 0.9 && blue[0] < 0.1)
    let split = try edge(blueBottomRows: 2)
    #expect(abs(split[0] - split[2]) < 0.1)
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

}

