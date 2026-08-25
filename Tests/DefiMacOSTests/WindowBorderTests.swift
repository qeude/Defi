import AppKit
import CoreGraphics
import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

struct WindowBorderTests {
  private let monitor = Rect(x: 0, y: 0, width: 1_512, height: 900)
  private let style = WindowBorderStyle(
    enabled: true,
    width: 4,
    activeColor: 0xffff_ffff,
    inactiveEnabled: false,
    inactiveColor: 0x66ff_ffff,
    captureEnabled: false
  )

  @Test
  func activeOnlyPlanRendersSingleBorderAndTracksVisibleWindows() {
    let selected = WindowID(rawValue: 2)
    let plan = planWindowBorders(
      frames: [
        FrameAssignment(
          windowID: WindowID(rawValue: 1),
          frame: Rect(x: 10, y: 20, width: 500, height: 800)
        ),
        FrameAssignment(
          windowID: selected,
          frame: Rect(x: 520, y: 20, width: 700, height: 800)
        ),
      ],
      selectedWindowID: selected,
      hiddenWindowIDs: [],
      monitorFrames: [monitor],
      style: style
    )

    #expect(plan.active?.windowID == selected)
    #expect(plan.active?.frame == Rect(x: 520, y: 20, width: 700, height: 800))
    #expect(plan.inactive.isEmpty)
    #expect(plan.tracked.map(\.windowID) == [WindowID(rawValue: 1), selected])
  }

  @Test
  func inactiveBordersRemainExplicitOptIn() {
    let selected = WindowID(rawValue: 2)
    let inactiveStyle = WindowBorderStyle(
      enabled: true,
      width: 4,
      activeColor: 0xffff_ffff,
      inactiveEnabled: true,
      inactiveColor: 0x66ff_ffff,
      captureEnabled: false
    )
    let plan = planWindowBorders(
      frames: (1...500).map {
        FrameAssignment(
          windowID: WindowID(rawValue: UInt64($0)),
          frame: Rect(x: 10, y: 20, width: 500, height: 800)
        )
      },
      selectedWindowID: selected,
      hiddenWindowIDs: [WindowID(rawValue: 3)],
      monitorFrames: [monitor],
      style: inactiveStyle
    )

    #expect(plan.active?.windowID == selected)
    #expect(plan.inactive.count == 498)
    #expect(plan.tracked.count == 499)
    #expect(plan.inactive.contains { $0.windowID == WindowID(rawValue: 3) } == false)
  }

  @Test
  func selectedWindowRemainsDecoratedAcrossStaleHiddenSnapshot() {
    let selected = WindowID(rawValue: 8)
    let plan = planWindowBorders(
      frames: [
        FrameAssignment(
          windowID: selected,
          frame: Rect(x: 100, y: 100, width: 800, height: 600)
        )
      ],
      selectedWindowID: selected,
      hiddenWindowIDs: [selected],
      monitorFrames: [monitor],
      style: style
    )

    #expect(plan.active?.windowID == selected)
  }

  @Test
  func disabledBorderProducesEmptyPlan() {
    let disabled = WindowBorderStyle(
      enabled: false,
      width: 4,
      activeColor: 0xffff_ffff,
      inactiveEnabled: true,
      inactiveColor: 0xffff_ffff,
      captureEnabled: false
    )
    let frame = FrameAssignment(
      windowID: WindowID(rawValue: 1),
      frame: Rect(x: 10, y: 20, width: 500, height: 800)
    )

    #expect(
      planWindowBorders(
        frames: [frame],
        selectedWindowID: frame.windowID,
        hiddenWindowIDs: [],
        monitorFrames: [monitor],
        style: disabled
      ).active == nil
    )
    #expect(
      planWindowBorders(
        frames: [frame],
        selectedWindowID: frame.windowID,
        hiddenWindowIDs: [],
        monitorFrames: [monitor],
        style: disabled
      ).tracked.isEmpty
    )
  }

  @Test
  func transparentActiveColorDoesNotDisableInactiveBorders() {
    let transparentActive = WindowBorderStyle(
      enabled: true,
      width: 4,
      activeColor: 0x00ff_ffff,
      inactiveEnabled: true,
      inactiveColor: 0xffff_ffff,
      captureEnabled: false
    )
    let selected = WindowID(rawValue: 1)
    let plan = planWindowBorders(
      frames: [
        FrameAssignment(
          windowID: selected,
          frame: Rect(x: 10, y: 20, width: 500, height: 800)
        )
      ],
      selectedWindowID: selected,
      hiddenWindowIDs: [],
      monitorFrames: [monitor],
      style: transparentActive
    )

    #expect(plan.active == nil)
    #expect(plan.inactive.count == 1)
    #expect(plan.tracked.count == 1)
  }

  @Test
  func overviewReusesConfiguredWindowBorderPolicy() {
    let active = overviewWindowBorderAppearance(isSelected: true, style: style)
    #expect(active?.color == style.activeColor)
    #expect(active?.width == style.width)
    #expect(overviewWindowBorderAppearance(isSelected: false, style: style) == nil)

    let inactiveStyle = WindowBorderStyle(
      enabled: true,
      width: 2,
      activeColor: 0xff11_2233,
      inactiveEnabled: true,
      inactiveColor: 0x8044_5566,
      captureEnabled: false
    )
    let inactive = overviewWindowBorderAppearance(
      isSelected: false,
      style: inactiveStyle
    )
    #expect(inactive?.color == inactiveStyle.inactiveColor)
    #expect(inactive?.width == inactiveStyle.width)
  }

  @Test
  func overviewOutsideBorderKeepsTheCardRadius() {
    let geometry = overviewWindowBorderGeometry(
      cardFrame: Rect(x: 100, y: 200, width: 800, height: 600),
      cardRadius: 9,
      width: 4,
      placement: .outside
    )

    #expect(geometry.frame == Rect(x: 98, y: 198, width: 804, height: 604))
    #expect(geometry.radius == 11)
  }

  @Test
  func borderAppearanceValuesAreNormalized() {
    #expect(borderCornerRadius(windowRadius: 9) == 9)
    #expect(borderOpacity(0xffc0_99ff) == 1)
    #expect(abs(borderOpacity(0x66c0_99ff) - 0.4) < 0.001)
  }

  @Test
  func nativeBorderMetadataFallsBackIndependently() {
    let observed = Rect(x: 10, y: 20, width: 800, height: 600)
    let planned = Rect(x: 30, y: 40, width: 900, height: 700)

    #expect(resolvedWindowBorderRadius(nativeRadius: 14) == 14)
    #expect(resolvedWindowBorderRadius(nativeRadius: nil) == 9)
    #expect(
      resolvedWindowBorderFrame(
        nativeFrame: nil,
        observedFrame: observed,
        plannedFrame: planned
      ) == observed
    )
    #expect(
      resolvedWindowBorderFrame(
        nativeFrame: nil,
        observedFrame: nil,
        plannedFrame: planned
      ) == planned
    )
  }

  @Test
  func segmentedBorderAllocatesOnlyNarrowEdgeSurfaces() {
    let geometries = windowBorderSegmentGeometries(
      windowFrame: Rect(x: 100, y: 200, width: 800, height: 600),
      width: 4,
      radius: 9
    )

    #expect(
      geometries == [
        WindowBorderSegmentGeometry(
          kind: .top,
          frame: Rect(x: 100, y: 200, width: 800, height: 13),
          pathOriginFromWindowBottom: CGPoint(x: 0, y: 587)
        ),
        WindowBorderSegmentGeometry(
          kind: .bottom,
          frame: Rect(x: 100, y: 787, width: 800, height: 13),
          pathOriginFromWindowBottom: .zero
        ),
        WindowBorderSegmentGeometry(
          kind: .left,
          frame: Rect(x: 100, y: 213, width: 13, height: 574),
          pathOriginFromWindowBottom: CGPoint(x: 0, y: 13)
        ),
        WindowBorderSegmentGeometry(
          kind: .right,
          frame: Rect(x: 887, y: 213, width: 13, height: 574),
          pathOriginFromWindowBottom: CGPoint(x: 787, y: 13)
        ),
      ]
    )
    let segmentedPixels = geometries.reduce(0) {
      $0 + Int($1.frame.width * $1.frame.height)
    }
    #expect(segmentedPixels == 35_724)
    #expect(segmentedPixels < Int(800 * 600) / 10)
  }

  @Test
  func outsidePlacementShiftsSegmentsPastWindowBounds() throws {
    let windowFrame = Rect(x: 100, y: 200, width: 800, height: 600)
    let width = 4.0
    let radius = 9.0
    let geometries = windowBorderSegmentGeometries(
      windowFrame: windowFrame,
      width: width,
      radius: radius,
      placement: .outside
    )
    let ringFrame = Rect(
      x: windowFrame.x - width,
      y: windowFrame.y - width,
      width: windowFrame.width + width * 2,
      height: windowFrame.height + width * 2
    )
    let expected = windowBorderSegmentGeometries(
      windowFrame: ringFrame,
      width: width,
      radius: radius
    )
    #expect(geometries == expected)

    let top = try #require(geometries.first { $0.kind == .top })
    let bottom = try #require(geometries.first { $0.kind == .bottom })
    #expect(top.frame == Rect(x: 96, y: 196, width: 808, height: 13))
    #expect(bottom.frame == Rect(x: 96, y: 791, width: 808, height: 13))

    let insidePixels = windowBorderSegmentGeometries(
      windowFrame: windowFrame,
      width: width,
      radius: radius
    ).reduce(0) { $0 + Int($1.frame.width * $1.frame.height) }
    let outsidePixels = geometries.reduce(0) {
      $0 + Int($1.frame.width * $1.frame.height)
    }
    #expect(
      Double(outsidePixels) < Double(insidePixels) * 1.15
    )
  }

  @Test
  func borderPlacementParsesConfigValues() {
    #expect(WindowBorderPlacement(configValue: "inside") == .inside)
    #expect(WindowBorderPlacement(configValue: "outside") == .outside)
    #expect(WindowBorderPlacement(configValue: "bogus") == .inside)
  }

  @Test
  func windowServerBoundsBecomeValidatedBorderFrames() {
    #expect(
      normalizedWindowBorderFrame(
        CGRect(x: -120, y: 24, width: 1_200, height: 800)
      ) == Rect(x: -120, y: 24, width: 1_200, height: 800)
    )
    #expect(
      normalizedWindowBorderFrame(
        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 800)
      ) == nil
    )
    #expect(
      normalizedWindowBorderFrame(
        CGRect(x: 0, y: 0, width: 0, height: 800)
      ) == nil
    )
  }

  @Test
  func nativeBoundsSnapshotQueriesEachWindowOnce() {
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    var queryCounts: [WindowID: Int] = [:]

    let snapshot = windowBorderFrameSnapshot(windowIDs: [first, second]) { windowID in
      queryCounts[windowID, default: 0] += 1
      return windowID == first
        ? Rect(x: 10, y: 20, width: 800, height: 600)
        : nil
    }

    #expect(snapshot[first] == Rect(x: 10, y: 20, width: 800, height: 600))
    #expect(snapshot[second] == nil)
    #expect(queryCounts == [first: 1, second: 1])
  }

  @Test @MainActor
  func rapidSelectionKeepsLatestActiveIdentity() {
    let manager = WindowBorderManager()
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    let third = WindowID(rawValue: 3)

    manager.prepareForSelection(first, displayedFrame: nil)
    #expect(manager.activeWindowID == first)

    manager.prepareForSelection(second, displayedFrame: nil)
    #expect(manager.activeWindowID == second)

    manager.prepareForSelection(third, displayedFrame: nil)
    #expect(manager.activeWindowID == third)
  }

  @Test @MainActor
  func suppressedBordersStayHiddenUntilRestored() {
    let manager = WindowBorderManager()
    let windowID = WindowID(rawValue: 1)
    let frame = Rect(x: 100, y: 100, width: 800, height: 600)
    let plan = planWindowBorders(
      frames: [FrameAssignment(windowID: windowID, frame: frame)],
      selectedWindowID: windowID,
      hiddenWindowIDs: [],
      monitorFrames: [monitor],
      style: style
    )

    manager.prepareForSelection(windowID, displayedFrame: frame)
    manager.sync(
      plan,
      displayedFrames: [windowID: frame],
      stacking: frontmostStacking(for: windowID)
    )
    #expect(manager.performance.visible == 1)

    manager.setSuppressed(true)
    manager.prepareForSelection(windowID, displayedFrame: frame)
    manager.sync(
      plan,
      displayedFrames: [windowID: frame],
      stacking: frontmostStacking(for: windowID)
    )
    manager.revealPendingBorders()
    #expect(manager.performance.visible == 0)

    manager.setSuppressed(false)
    manager.prepareForSelection(windowID, displayedFrame: frame)
    manager.sync(
      plan,
      displayedFrames: [windowID: frame],
      stacking: frontmostStacking(for: windowID)
    )
    #expect(manager.performance.visible == 1)
  }

  @Test @MainActor
  func activeSelectionReusesDormantBorderPanels() {
    let manager = WindowBorderManager()
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    let frame = Rect(x: 100, y: 100, width: 800, height: 600)
    let firstPlan = planWindowBorders(
      frames: [FrameAssignment(windowID: first, frame: frame)],
      selectedWindowID: first,
      hiddenWindowIDs: [],
      monitorFrames: [monitor],
      style: style
    )

    manager.prepareForSelection(first, displayedFrame: frame)
    manager.sync(
      firstPlan,
      displayedFrames: [first: frame],
      stacking: frontmostStacking(for: first)
    )
    #expect(manager.performance.allocated == 1)

    manager.prepareForSelection(second, displayedFrame: frame)

    #expect(manager.activeWindowID == second)
    #expect(manager.performance.allocated == 1)
  }

  @Test @MainActor
  func ownedSurfaceWindowIDRemainsReadableAfterRapidOverlayChanges() {
    let manager = WindowBorderManager()
    let frame = Rect(x: 100, y: 100, width: 800, height: 600)

    for rawWindowID in 1...24 {
      let windowID = WindowID(rawValue: UInt64(rawWindowID))
      let plan = planWindowBorders(
        frames: [FrameAssignment(windowID: windowID, frame: frame)],
        selectedWindowID: windowID,
        hiddenWindowIDs: [],
        monitorFrames: [monitor],
        style: style
      )
      manager.sync(
        plan,
        displayedFrames: [windowID: frame],
        stacking: frontmostStacking(for: windowID)
      )

      _ = manager.ownedSurfaceWindowID
    }
  }

  @Test @MainActor
  func initialInactiveBorderBatchReservesEveryAllocation() {
    let manager = WindowBorderManager()
    let windowIDs = (1...3).map { WindowID(rawValue: UInt64($0)) }
    let frames = Dictionary(
      uniqueKeysWithValues: windowIDs.enumerated().map { index, windowID in
        let frame = Rect(
          x: Double(index * 400),
          y: 100,
          width: 380,
          height: 600
        )
        return (windowID, frame)
      }
    )
    let inactiveStyle = WindowBorderStyle(
      enabled: true,
      width: 4,
      activeColor: 0xffff_ffff,
      inactiveEnabled: true,
      inactiveColor: 0x66ff_ffff,
      captureEnabled: false
    )
    let plan = planWindowBorders(
      frames: frames.map { FrameAssignment(windowID: $0.key, frame: $0.value) },
      selectedWindowID: windowIDs[0],
      hiddenWindowIDs: [],
      monitorFrames: [monitor],
      style: inactiveStyle
    )

    manager.sync(
      plan,
      displayedFrames: frames,
      stacking: frontmostStacking(for: windowIDs[0])
    )

    #expect(manager.performance.allocated == 3)
    #expect(manager.performance.visible == 3)
  }

  @Test @MainActor
  func borderPanelsFloatOnlyWhileActiveWindowIsFrontmost() {
    let target = WindowID(rawValue: 1)
    let pictureInPicture = WindowID(rawValue: 2)
    let overlay = BorderOverlay(windowID: target)

    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.normal.rawValue
      }
    )
    overlay.setStacking(frontmostStacking(for: target))
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.floating.rawValue
      }
    )
    overlay.setStacking(.inactive(for: target))
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.normal.rawValue
      }
    )

    overlay.setStacking(
      WindowBorderStacking(
        targetWindowID: target,
        activeWindowIsFrontmost: true,
        upperBoundWindowID: pictureInPicture,
        upperBoundLevel: NSWindow.Level.floating.rawValue
      )
    )
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.floating.rawValue
      }
    )
    #expect(
      overlay.upperBoundWindowNumbers.allSatisfy {
        $0 == Int(pictureInPicture.rawValue)
      }
    )

    overlay.setStacking(frontmostStacking(for: target))
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.floating.rawValue
      }
    )
    #expect(
      overlay.upperBoundWindowNumbers.allSatisfy { $0 == nil }
    )
  }

  private func frontmostStacking(
    for windowID: WindowID
  ) -> WindowBorderStacking {
    WindowBorderStacking(
      targetWindowID: windowID,
      activeWindowIsFrontmost: true,
      upperBoundWindowID: nil,
      upperBoundLevel: nil
    )
  }
}
