import AppKit
import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

@Suite
struct OverviewScrollTests {
  private let workspaceID = WorkspaceID(rawValue: "web")

  @Test
  func `Precise deltas remain continuous on either axis`() {
    var viewport = OverviewViewport()
    let zoom = 0.25
    let stride = overviewWorkspaceStride(boundsHeight: 900, zoom: zoom)
    let workspaceHeight = stride - 28

    for _ in 0..<100 {
      viewport = overviewViewportAfterScroll(
        viewport,
        delta: NSPoint(x: 0, y: -1),
        hasPreciseScrollingDeltas: true,
        viewSize: NSSize(width: 1_512, height: 900),
        zoom: zoom,
        activeWorkspaceIndex: 1,
        workspaceCount: 9,
        horizontalWorkspaceID: workspaceID,
        maximumHorizontalOffset: 2
      )
      viewport = overviewViewportAfterScroll(
        viewport,
        delta: NSPoint(x: -1, y: 0),
        hasPreciseScrollingDeltas: true,
        viewSize: NSSize(width: 1_512, height: 900),
        zoom: zoom,
        activeWorkspaceIndex: 1,
        workspaceCount: 9,
        horizontalWorkspaceID: workspaceID,
        maximumHorizontalOffset: 2
      )
    }

    #expect(abs(viewport.workspaceOffset - 100 / stride) < 0.000_001)
    #expect(
      abs(
        viewport.horizontalOffsets[workspaceID, default: 0]
          - 100.0 / (1_512 * workspaceHeight / 900)
      ) < 0.000_001
    )
  }

  @Test
  func `Scroll uses the same horizontal bounds as keyboard paging`() {
    let maximumOffset = 2.5
    let end = overviewViewportAfterScroll(
      OverviewViewport(),
      delta: NSPoint(x: -100_000, y: 0),
      hasPreciseScrollingDeltas: true,
      viewSize: NSSize(width: 1_512, height: 900),
      activeWorkspaceIndex: 1,
      workspaceCount: 9,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: maximumOffset
    )
    let start = overviewViewportAfterScroll(
      end,
      delta: NSPoint(x: 100_000, y: 0),
      hasPreciseScrollingDeltas: true,
      viewSize: NSSize(width: 1_512, height: 900),
      activeWorkspaceIndex: 1,
      workspaceCount: 9,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: maximumOffset
    )

    #expect(end.horizontalOffsets[workspaceID] == maximumOffset)
    #expect(start.horizontalOffsets[workspaceID] == 0)
  }

  @Test
  func `Vertical trackpad movement does not leak into the horizontal ribbon`() {
    let viewport = overviewViewportAfterScroll(
      OverviewViewport(),
      delta: NSPoint(x: -3, y: -20),
      hasPreciseScrollingDeltas: true,
      viewSize: NSSize(width: 1_512, height: 900),
      activeWorkspaceIndex: 1,
      workspaceCount: 9,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: 2
    )

    #expect(viewport.workspaceOffset > 0)
    #expect(viewport.horizontalOffsets[workspaceID, default: 0] == 0)
  }

  @Test
  func `Moving a selection clamps its source ribbon and discards the stale target`() {
    let sourceWorkspaceID = WorkspaceID(rawValue: "dev")
    let transition = overviewViewportTransitionAfterSelectionAlignment(
      current: OverviewViewport(horizontalOffsets: [workspaceID: 0, sourceWorkspaceID: 2]),
      pendingTarget: OverviewViewport(
        horizontalOffsets: [workspaceID: 0, sourceWorkspaceID: 2]
      ),
      animationTarget: nil,
      workspaceID: workspaceID,
      scrollOffset: 1,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceMaximumHorizontalOffset: 1,
      movedSelection: true
    )

    #expect(transition.current.horizontalOffsets[workspaceID] == 1)
    #expect(transition.current.horizontalOffsets[sourceWorkspaceID] == 1)
    #expect(transition.target == nil)
  }

  @Test
  func `A strip centered with edge space does not jump inward when scrolled outward`() {
    let step = 1.0 / (1_512 * (overviewWorkspaceStride(boundsHeight: 900, zoom: 0.25) - 28) / 900)
    func scrolled(from start: Double, byX x: Double, maximum: Double) -> Double {
      overviewViewportAfterScroll(
        OverviewViewport(horizontalOffsets: [workspaceID: start]),
        delta: NSPoint(x: x, y: 0),
        hasPreciseScrollingDeltas: true,
        viewSize: NSSize(width: 1_512, height: 900),
        zoom: 0.25,
        activeWorkspaceIndex: 1,
        workspaceCount: 9,
        horizontalWorkspaceID: workspaceID,
        maximumHorizontalOffset: maximum
      ).horizontalOffsets[workspaceID, default: 0]
    }

    #expect(scrolled(from: -0.25, byX: 1, maximum: 1) == -0.25)
    #expect(abs(scrolled(from: -0.25, byX: -1, maximum: 1) - (-0.25 + step)) < 0.000_001)
    #expect(scrolled(from: 1.25, byX: -1, maximum: 1) == 1.25)
    #expect(abs(scrolled(from: 1.25, byX: 1, maximum: 1) - (1.25 - step)) < 0.000_001)
    #expect(scrolled(from: 0.5, byX: 100_000, maximum: 1) == 0)
    #expect(scrolled(from: 0.5, byX: -100_000, maximum: 1) == 1)
  }

  @Test
  func `Paging keeps a strip outside the normal range where it is`() {
    #expect(overviewHorizontalOffset(-0.25 - 1, from: -0.25, maximum: 1) == -0.25)
    #expect(overviewHorizontalOffset(-0.25 + 1, from: -0.25, maximum: 1) == 0.75)
    #expect(overviewHorizontalOffset(1.25 + 1, from: 1.25, maximum: 1) == 1.25)
    #expect(overviewHorizontalOffset(1.25 - 1, from: 1.25, maximum: 1) == 0.25)
    #expect(overviewHorizontalOffset(0.5 + 1, from: 0.5, maximum: 1) == 1)
  }

  @Test
  func `Moving a selection keeps a centered source ribbon with edge space`() {
    let sourceWorkspaceID = WorkspaceID(rawValue: "dev")
    let transition = overviewViewportTransitionAfterSelectionAlignment(
      current: OverviewViewport(horizontalOffsets: [workspaceID: 0, sourceWorkspaceID: -0.25]),
      pendingTarget: nil,
      animationTarget: nil,
      workspaceID: workspaceID,
      scrollOffset: 0,
      sourceWorkspaceID: sourceWorkspaceID,
      sourceMaximumHorizontalOffset: 1,
      movedSelection: true
    )

    #expect(transition.current.horizontalOffsets[sourceWorkspaceID] == -0.25)
  }
}
