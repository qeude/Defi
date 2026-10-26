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
          frame: Rect(x: 8, y: 88, width: 312, height: 624)
        ))
  }

  @Test
  func `Two half columns fit the screen even when the app rounds its width up`() {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: WindowID(rawValue: 1), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 2), width: .fraction(0.5)),
      ]
    )
    // A terminal answered a request with 2 more points; that is rounding, not a minimum.
    let windows = [1, 2].map { raw in
      Window(id: WindowID(rawValue: UInt64(raw)), appID: "ghostty", title: "",
        frame: Rect(x: 0, y: 0, width: 1272, height: 1360), minimumTiledWidth: 1272)
    }
    let frames = computeLayout(
      workspace: workspace, viewport: Rect(x: 0, y: 0, width: 2560, height: 1400),
      windows: windows, settings: settings
    ).map(\.frame)
    #expect(frames.map(\.width) == frames.map { _ in frames[0].width })
    #expect(frames[1].x + frames[1].width <= 2560 - Double(settings.outerRightGap))
  }

  @Test
  func `A window is asked for exactly its own minimum or maximum width, its gaps outside it`() {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: WindowID(rawValue: 1), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 2), width: .fraction(0.5)),
        Column(window: WindowID(rawValue: 3), width: .fraction(0.5)),
      ]
    )
    let windows = [
      Window(id: WindowID(rawValue: 1), appID: "a", title: "",
        frame: Rect(x: 0, y: 0, width: 1500, height: 1384), minimumTiledWidth: 1500),
      Window(id: WindowID(rawValue: 2), appID: "b", title: "",
        frame: Rect(x: 0, y: 0, width: 740, height: 1384), maximumTiledWidth: 740),
      Window(id: WindowID(rawValue: 3), appID: "c", title: "",
        frame: Rect(x: 0, y: 0, width: 1500, height: 1384), minimumTiledWidth: 1500),
    ]
    let frames = computeLayout(
      workspace: workspace, viewport: Rect(x: 0, y: 0, width: 2560, height: 1400),
      windows: windows, settings: settings
    ).map(\.frame)
    #expect(frames == [
      Rect(x: 8, y: 8, width: 1500, height: 1384),
      Rect(x: 1516, y: 8, width: 740, height: 1384),
      Rect(x: 2264, y: 8, width: 1500, height: 1384),
    ])
  }

  /// Two half-width columns on a 2560-point display; `settled` maps a column to the
  /// width its window settled at when asked for the 1268 points it is given.
  private func halfColumns(settled: [Int: Double]) -> [Rect] {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [1, 2].map { Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5)) }
    )
    let windows = [1, 2].map { index in
      var window = Window(id: WindowID(rawValue: UInt64(index)), appID: "app", title: "",
        frame: Rect(x: 0, y: 0, width: 1268, height: 1384))
      if let width = settled[index] {
        let x = index == 1 ? 8.0 : 1284.0
        window.tiledSizeAcceptance = TiledSizeAcceptance(
          requested: Rect(x: x, y: 8, width: 1268, height: 1384),
          accepted: Rect(x: x, y: 8, width: width, height: 1384))
      }
      return window
    }
    return computeLayout(
      workspace: workspace, viewport: Rect(x: 0, y: 0, width: 2560, height: 1400),
      windows: windows, settings: settings
    ).map(\.frame)
  }

  @Test
  func `A column that snaps narrower keeps its gaps and the next column absorbs it`() {
    #expect(halfColumns(settled: [1: 1266]) == [
      Rect(x: 8, y: 8, width: 1266, height: 1384),
      Rect(x: 1282, y: 8, width: 1270, height: 1384),
    ])
  }

  @Test
  func `A last column that snaps is absorbed by the previous column`() {
    #expect(halfColumns(settled: [2: 1266]) == [
      Rect(x: 8, y: 8, width: 1270, height: 1384),
      Rect(x: 1286, y: 8, width: 1266, height: 1384),
    ])
  }

  @Test
  func `A column that snaps wider shrinks the next column by as much`() {
    #expect(halfColumns(settled: [1: 1271]) == [
      Rect(x: 8, y: 8, width: 1271, height: 1384),
      Rect(x: 1287, y: 8, width: 1265, height: 1384),
    ])
  }

  @Test
  func `A neighbour that settled its own height does not absorb`() {
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [1, 2].map { Column(window: WindowID(rawValue: UInt64($0)), width: .fraction(0.5)) }
    )
    var windows = [1, 2].map {
      Window(id: WindowID(rawValue: UInt64($0)), appID: "app", title: "",
        frame: Rect(x: 0, y: 0, width: 1268, height: 1384))
    }
    windows[0].tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 8, y: 8, width: 1268, height: 1384),
      accepted: Rect(x: 8, y: 8, width: 1266, height: 1384))
    windows[1].tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 1284, y: 8, width: 1268, height: 1384),
      accepted: Rect(x: 1284, y: 8, width: 1268, height: 1380))
    let frames = computeLayout(
      workspace: workspace, viewport: Rect(x: 0, y: 0, width: 2560, height: 1400),
      windows: windows, settings: settings
    ).map(\.frame)
    #expect(frames == [
      Rect(x: 8, y: 8, width: 1266, height: 1384),
      Rect(x: 1282, y: 10, width: 1268, height: 1380),
    ])
  }

  @Test
  func `Columns that all snap keep their gaps and leave the difference at the outer edge`() {
    #expect(halfColumns(settled: [1: 1266, 2: 1266]) == [
      Rect(x: 8, y: 8, width: 1266, height: 1384),
      Rect(x: 1282, y: 8, width: 1266, height: 1384),
    ])
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

  @Test(arguments: [(0.0, true), (4.0, false)])
  func `Accepted compact size survives only its own width request`(shift: Double, reused: Bool) {
    let gaps = LayoutSettings(
      innerHorizontalGap: 4, innerVerticalGap: 4,
      outerTopGap: 8, outerRightGap: 8,
      outerBottomGap: 8, outerLeftGap: 8
    )
    let deviceID = WindowID(rawValue: 1)
    var device = Window(
      id: deviceID, appID: "com.apple.dt.Devices", title: "Simulator",
      frame: Rect(x: 0, y: 0, width: 385, height: 841),
      maximumTiledHeight: 1_368
    )
    // The strip is 2560 - 8 - 8 + 4 + 4 wide, so the request is 0.44 * 2552 - 4 - 4
    // = 1114.88 wide and 1352 tall wherever the column sits.
    device.tiledSizeAcceptance = TiledSizeAcceptance(
      requested: Rect(x: 0, y: 0, width: 1_114.88 + shift, height: 1_352),
      accepted: device.frame
    )
    let others = [WindowID(rawValue: 2), WindowID(rawValue: 3)].map {
      Window(id: $0, appID: "other", title: "Other",
        frame: Rect(x: 0, y: 0, width: 1_280, height: 1_368))
    }
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(window: others[0].id, width: .fraction(0.5)),
        Column(window: deviceID, width: .fraction(0.44)),
        Column(window: others[1].id, width: .fraction(0.5)),
      ],
      focusedColumn: 1
    )
    let frames = computeLayout(
      workspace: workspace,
      viewport: Rect(x: 0, y: 0, width: 2_560, height: 1_368),
      windows: [others[0], device, others[1]], settings: gaps
    )
    let width = frames.first { $0.windowID == deviceID }!.frame.width
    #expect((width == 385) == reused)
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
