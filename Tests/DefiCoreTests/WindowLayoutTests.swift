import DefiCore
import DefiModel
import Testing

struct WindowLayoutTests {
  private let settings = LayoutSettings()

  @Test
  func `Intrinsic size window stays centered in tile`() {
    var workspace = Workspace(id: WorkspaceID(rawValue: "1"))
    insertNewWindow(
      WindowID(rawValue: 1),
      width: .pixels(500),
      into: &workspace,
      settings: settings
    )
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "Simulator",
      title: "iPhone",
      frame: Rect(x: 0, y: 0, width: 320, height: 640),
      intrinsicSize: true
    )

    let diff = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_000, height: 800),
      windows: [window],
      settings: settings
    )

    #expect(
      diff[0]
        == FrameAssignment(
          windowID: WindowID(rawValue: 1),
          frame: Rect(x: 8, y: 88, width: 304, height: 624)
        ))
  }

  @Test
  func `Each viewport produces its own monitor sized layout`() {
    let noGaps = LayoutSettings(
      defaultColumnWidth: 0.8,
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [Column(window: WindowID(rawValue: 1), width: .fraction(0.8))]
    )

    let laptop = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_500, height: 900),
      settings: noGaps
    )[0].frame
    let external = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 1_500, y: 30, width: 2_560, height: 1_362),
      settings: noGaps
    )[0].frame

    #expect(laptop == Rect(x: 0, y: 0, width: 1_200, height: 900))
    #expect(external == Rect(x: 1_500, y: 30, width: 2_048, height: 1_362))
  }

  @Test
  func `Accepted compact size shrinks its column and scroll extent`() {
    let noGaps = LayoutSettings(
      innerHorizontalGap: 0,
      innerVerticalGap: 0,
      outerTopGap: 0,
      outerRightGap: 0,
      outerBottomGap: 0,
      outerLeftGap: 0
    )
    let firstID = WindowID(rawValue: 1)
    let secondID = WindowID(rawValue: 2)
    let thirdID = WindowID(rawValue: 3)
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: firstID, width: .fraction(0.44)),
        Column(window: secondID, width: .fraction(0.5)),
        Column(window: thirdID, width: .fraction(0.5)),
      ],
      focusedColumn: 1
    )
    let compact = Window(
      id: firstID,
      appID: "device-hub",
      title: "Devices",
      frame: Rect(x: 161.5, y: 311.5, width: 338, height: 748),
      minimumTiledWidth: 196,
      maximumTiledWidth: 661,
      maximumTiledHeight: 1371
    )
    var compactWithAcceptance = compact
    compactWithAcceptance.tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 0, y: 0, width: 661, height: 1_371),
      accepted: compact.frame
    )
    let neighbor = Window(
      id: secondID,
      appID: "neighbor",
      title: "Neighbor",
      frame: Rect(x: 0, y: 0, width: 1_280, height: 1_371)
    )
    let last = Window(
      id: thirdID,
      appID: "last",
      title: "Last",
      frame: Rect(x: 0, y: 0, width: 1_280, height: 1_371)
    )
    let viewport = Rect(x: 0, y: 0, width: 2_560, height: 1_371)

    let compactLayout = computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: [compactWithAcceptance, neighbor, last],
      settings: noGaps
    )

    #expect(compactLayout[0].frame == Rect(x: 0, y: 311.5, width: 338, height: 748))
    #expect(compactLayout[1].frame.x == 338)
    #expect(
      focusedColumnLeftScrollOffset(
        workspace: workspace,
        viewport: viewport,
        windows: [compactWithAcceptance, neighbor, last],
        settings: noGaps
      ) == 338.0 / 2_560.0
    )

    let normalLayout = computeLayout(
      workspace: workspace,
      viewport: viewport,
      windows: [compact, neighbor, last],
      settings: noGaps
    )
    #expect(normalLayout[0].frame.width == 661)
    #expect(normalLayout[1].frame.x == 661)
  }

  @Test
  func `Unbounded window ignores a stale accepted compact size`() {
    let noGaps = LayoutSettings(
      innerHorizontalGap: 0, innerVerticalGap: 0,
      outerTopGap: 0, outerRightGap: 0,
      outerBottomGap: 0, outerLeftGap: 0
    )
    let firstID = WindowID(rawValue: 1)
    let secondID = WindowID(rawValue: 2)
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: firstID, width: .pixels(500)),
        Column(window: secondID, width: .pixels(500)),
      ]
    )
    var clamped = Window(
      id: firstID, appID: "clamped", title: "Clamped",
      frame: Rect(x: 0, y: 0, width: 600, height: 738)
    )
    clamped.tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 0, y: 0, width: 500, height: 800),
      accepted: clamped.frame
    )
    let neighbor = Window(
      id: secondID, appID: "neighbor", title: "Neighbor",
      frame: Rect(x: 0, y: 0, width: 500, height: 800)
    )
    let frames = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 1_200, height: 800),
      windows: [clamped, neighbor], settings: noGaps
    )
    #expect(frames[0].frame == Rect(x: 0, y: 0, width: 500, height: 800))
    #expect(frames[1].frame.x == 500)
  }

}
