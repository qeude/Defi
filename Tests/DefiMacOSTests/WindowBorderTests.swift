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
      activeWindowIsFrontmost: true
    )
    #expect(manager.performance.allocated == 1)

    manager.prepareForSelection(second, displayedFrame: frame)

    #expect(manager.activeWindowID == second)
    #expect(manager.performance.allocated == 1)
  }

  @Test @MainActor
  func borderPanelsFloatOnlyWhileActiveWindowIsFrontmost() {
    let overlay = BorderOverlay(windowID: WindowID(rawValue: 1))

    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.normal.rawValue
      }
    )
    overlay.setFrontmost(true)
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.floating.rawValue
      }
    )
    overlay.setFrontmost(false)
    #expect(
      overlay.windowLevelRawValues.allSatisfy {
        $0 == NSWindow.Level.normal.rawValue
      }
    )
  }
}
