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
  func `Horizontal trackpad movement follows projected ribbon pixels`() {
    let viewport = overviewViewportAfterScroll(
      OverviewViewport(),
      delta: NSPoint(x: -100, y: 0),
      hasPreciseScrollingDeltas: true,
      viewSize: NSSize(width: 1_512, height: 900),
      activeWorkspaceIndex: 1,
      workspaceCount: 9,
      horizontalWorkspaceID: workspaceID,
      maximumHorizontalOffset: 2
    )
    let workspaceHeight = overviewWorkspaceStride(boundsHeight: 900) - 28
    let projectedPointsPerScrollUnit = 1_512.0 * workspaceHeight / 900

    #expect(
      abs(
        viewport.horizontalOffsets[workspaceID, default: 0]
          - 100.0 / projectedPointsPerScrollUnit
      ) < 0.000_001
    )
  }
}
