import DefiCore
import DefiModel
import Testing

struct OverviewTests {
  let monitorID = MonitorID(rawValue: 1)
  let monitorFrame = Rect(x: 0, y: 0, width: 1_000, height: 800)

  @Test
  func `Projection culls workspaces without mutating real scroll`() {
    let workspaceIDs = (1...9).map { WorkspaceID(rawValue: String($0)) }
    var active = Workspace(
      id: workspaceIDs[4],
      columns: [Column(window: WindowID(rawValue: 1), width: .fraction(0.8))],
      scrollOffset: 0.25,
      targetScrollOffset: 0.25
    )
    active.focusedColumn = 0
    let monitor = Monitor(
      id: monitorID,
      workspaces: workspaceIDs.map { $0 == active.id ? active : Workspace(id: $0) },
      activeWorkspace: active.id
    )
    let snapshot = OverviewSnapshot(
      monitors: [monitor],
      monitorFrames: [monitorID: monitorFrame],
      windows: [
        WindowID(rawValue: 1): Window(
          id: WindowID(rawValue: 1),
          appID: "app",
          title: "one",
          frame: monitorFrame
        )
      ]
    )

    let projection = projectOverview(
      snapshot: snapshot,
      monitorID: monitorID,
      bounds: monitorFrame,
      viewport: OverviewViewport(horizontalOffsets: [active.id: 1]),
      layout: LayoutSettings()
    )

    #expect(projection.workspaces.count < monitor.workspaces.count)
    #expect(projection.workspaces.contains(where: { $0.workspaceID == active.id }))
    #expect(snapshot.monitors[0].workspaces[4].scrollOffset == 0.25)
  }

  @Test
  func `Adjacent active workspace projections retain entering and leaving ribbons`() {
    let workspaceIDs = (1...9).map { WorkspaceID(rawValue: String($0)) }
    let workspaces = workspaceIDs.map { Workspace(id: $0) }
    func projection(activeIndex: Int) -> OverviewProjection {
      projectOverview(
        snapshot: OverviewSnapshot(
          monitors: [
            Monitor(
              id: monitorID,
              workspaces: workspaces,
              activeWorkspace: workspaceIDs[activeIndex]
            )
          ],
          monitorFrames: [monitorID: monitorFrame],
          windows: [:]
        ),
        monitorID: monitorID,
        bounds: monitorFrame,
        viewport: OverviewViewport(),
        layout: LayoutSettings()
      )
    }
    let source = projection(activeIndex: 4)
    let target = projection(activeIndex: 5)
    let sourceIDs = Set(source.workspaces.map(\.workspaceID))
    let targetIDs = Set(target.workspaces.map(\.workspaceID))
    let isVisible: (OverviewWorkspaceProjection) -> Bool = {
      $0.frame.y < monitorFrame.y + monitorFrame.height
        && $0.frame.y + $0.frame.height > monitorFrame.y
    }
    let sourceVisibleIDs = Set(
      source.workspaces.filter(isVisible).map(\.workspaceID)
    )
    let targetVisibleIDs = Set(
      target.workspaces.filter(isVisible).map(\.workspaceID)
    )

    #expect(targetVisibleIDs.isSubset(of: sourceIDs))
    #expect(sourceVisibleIDs.isSubset(of: targetIDs))
  }

  @Test
  func `Workspace projects as a centered half-height ribbon`() {
    let windowID = WindowID(rawValue: 1)
    let floatingID = WindowID(rawValue: 2)
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "dev"),
      columns: [Column(window: windowID, width: .fraction(1))],
      floatingWindows: [floatingID]
    )
    let bounds = Rect(x: 40, y: 20, width: 1_200, height: 600)
    let projection = projectOverview(
      snapshot: OverviewSnapshot(
        monitors: [
          Monitor(
            id: monitorID,
            workspaces: [workspace],
            activeWorkspace: workspace.id
          )
        ],
        monitorFrames: [monitorID: monitorFrame],
        windows: [
          windowID: Window(
            id: windowID,
            appID: "app",
            title: "window",
            frame: monitorFrame
          ),
          floatingID: Window(
            id: floatingID,
            appID: "floating",
            title: "floating",
            frame: Rect(x: 200, y: 100, width: 400, height: 200),
            floating: true
          ),
        ],
        floatingFrames: [
          floatingID: Rect(x: 200, y: 100, width: 400, height: 200)
        ]
      ),
      monitorID: monitorID,
      bounds: bounds,
      viewport: OverviewViewport(),
      layout: LayoutSettings()
    )
    let ribbon = projection.workspaces[0].frame
    let tiled = projection.workspaces[0].windows.first {
      if case .tiled = $0.layer { return true }
      return false
    }!
    let floating = projection.workspaces[0].windows.first {
      $0.layer == .floating
    }!

    #expect(ribbon.x == bounds.x)
    #expect(ribbon.width == bounds.width)
    #expect(ribbon.height == (bounds.height - 56) / 2)
    #expect(ribbon.y == bounds.y + (bounds.height - ribbon.height) / 2)
    #expect(tiled.frame.x > ribbon.x + 28)
    #expect(tiled.frame.x < ribbon.x + ribbon.width / 4)
    #expect(floating.frame.width / floating.frame.height == 2)
  }

  @Test
  func `Adjacent workspaces remain half visible`() {
    let workspaces = (0..<3).map { Workspace(id: WorkspaceID(rawValue: "\($0)")) }
    let bounds = Rect(x: 0, y: 20, width: 1_200, height: 600)
    let projection = projectOverview(
      snapshot: OverviewSnapshot(
        monitors: [
          Monitor(
            id: monitorID,
            workspaces: workspaces,
            activeWorkspace: workspaces[1].id
          )
        ],
        monitorFrames: [monitorID: monitorFrame],
        windows: [:]
      ),
      monitorID: monitorID,
      bounds: bounds,
      viewport: OverviewViewport(),
      layout: LayoutSettings()
    )

    let previous = projection.workspaces[0].frame
    let active = projection.workspaces[1].frame
    let next = projection.workspaces[2].frame
    #expect(active.y + active.height / 2 == bounds.y + bounds.height / 2)
    #expect(previous.y + previous.height - bounds.y == active.height / 2)
    #expect(bounds.y + bounds.height - next.y == active.height / 2)
  }

  @Test
  func `Zoom scales workspace ribbons`() {
    let workspace = Workspace(id: WorkspaceID(rawValue: "dev"))
    let bounds = Rect(x: 0, y: 0, width: 1_200, height: 600)
    let projection = projectOverview(
      snapshot: OverviewSnapshot(
        monitors: [
          Monitor(
            id: monitorID,
            workspaces: [workspace],
            activeWorkspace: workspace.id
          )
        ],
        monitorFrames: [monitorID: monitorFrame],
        windows: [:]
      ),
      monitorID: monitorID,
      bounds: bounds,
      viewport: OverviewViewport(),
      layout: LayoutSettings(),
      zoom: 0.25
    )

    #expect(projection.workspaces[0].frame.height == (bounds.height - 56) * 0.25)
  }

  @Test
  func `Hit test prefers floating windows`() {
    let tiledID = WindowID(rawValue: 1)
    let floatingID = WindowID(rawValue: 2)
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [Column(window: tiledID, width: .fraction(1))],
      floatingWindows: [floatingID]
    )
    let snapshot = OverviewSnapshot(
      monitors: [Monitor(id: monitorID, workspaces: [workspace], activeWorkspace: workspace.id)],
      monitorFrames: [monitorID: monitorFrame],
      windows: [
        tiledID: Window(id: tiledID, appID: "app", title: "tiled", frame: monitorFrame),
        floatingID: Window(
          id: floatingID,
          appID: "app",
          title: "floating",
          frame: Rect(x: 200, y: 200, width: 400, height: 300),
          floating: true
        ),
      ]
    )
    let projection = projectOverview(
      snapshot: snapshot,
      monitorID: monitorID,
      bounds: monitorFrame,
      viewport: OverviewViewport(),
      layout: LayoutSettings()
    )
    let floating = projection.workspaces[0].windows.last!
    let hit = projection.hitTest(
      OverviewPoint(x: floating.frame.x + 1, y: floating.frame.y + 1)
    )

    #expect(
      hit == .window(
        windowID: floatingID,
        monitorID: monitorID,
        workspaceID: workspace.id
      )
    )
  }

  @Test
  func `Four scrolling columns remain reachable through overview scroll`() {
    let windowIDs = (1...4).map { WindowID(rawValue: UInt64($0)) }
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "terminals"),
      columns: windowIDs.map { Column(window: $0, width: .fraction(0.8)) }
    )
    let snapshot = OverviewSnapshot(
      monitors: [
        Monitor(
          id: monitorID,
          workspaces: [workspace],
          activeWorkspace: workspace.id
        )
      ],
      monitorFrames: [monitorID: monitorFrame],
      windows: Dictionary(uniqueKeysWithValues: windowIDs.map {
        ($0, Window(id: $0, appID: "terminal", title: "terminal", frame: monitorFrame))
      })
    )

    let visibleWindowIDs = Set([0.0, 0.8, 1.6, 2.4].flatMap { offset in
      projectOverview(
        snapshot: snapshot,
        monitorID: monitorID,
        bounds: monitorFrame,
        viewport: OverviewViewport(horizontalOffsets: [workspace.id: offset]),
        layout: LayoutSettings()
      ).workspaces[0].windows.map(\.windowID)
    })

    #expect(visibleWindowIDs == Set(windowIDs))
  }

  @Test
  func `Projection reports windows hidden on each side of the strip`() {
    let windowIDs = (1...8).map { WindowID(rawValue: UInt64($0)) }
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "terminals"),
      columns: windowIDs.map { Column(window: $0, width: .fraction(0.8)) }
    )
    let snapshot = OverviewSnapshot(
      monitors: [
        Monitor(
          id: monitorID,
          workspaces: [workspace],
          activeWorkspace: workspace.id
        )
      ],
      monitorFrames: [monitorID: monitorFrame],
      windows: Dictionary(uniqueKeysWithValues: windowIDs.map {
        ($0, Window(id: $0, appID: "terminal", title: "terminal", frame: monitorFrame))
      })
    )

    let start = projectOverview(
      snapshot: snapshot,
      monitorID: monitorID,
      bounds: monitorFrame,
      viewport: OverviewViewport(),
      layout: LayoutSettings()
    ).workspaces[0]
    let middle = projectOverview(
      snapshot: snapshot,
      monitorID: monitorID,
      bounds: monitorFrame,
      viewport: OverviewViewport(horizontalOffsets: [workspace.id: 1]),
      layout: LayoutSettings()
    ).workspaces[0]

    #expect(start.hiddenTiledWindowCountBefore == 0)
    #expect(start.hiddenTiledWindowCountAfter > 0)
    #expect(middle.hiddenTiledWindowCountBefore > 0)
    #expect(middle.hiddenTiledWindowCountAfter < start.hiddenTiledWindowCountAfter)
  }

  @Test
  func `Viewport interpolation moves both axes without losing offsets`() {
    let first = WorkspaceID(rawValue: "first")
    let second = WorkspaceID(rawValue: "second")
    let third = WorkspaceID(rawValue: "third")

    let viewport = interpolateOverviewViewport(
      from: OverviewViewport(
        workspaceOffset: 0,
        horizontalOffsets: [first: 0, second: 2]
      ),
      to: OverviewViewport(
        workspaceOffset: 2,
        horizontalOffsets: [first: 4, third: 3]
      ),
      progress: 0.25
    )

    #expect(viewport.workspaceOffset == 0.5)
    #expect(viewport.horizontalOffsets[first] == 1)
    #expect(viewport.horizontalOffsets[second] == 2)
    #expect(viewport.horizontalOffsets[third] == 3)
  }

  @Test
  func `Projection interpolation follows reordered windows`() throws {
    let workspaceID = WorkspaceID(rawValue: "dev")
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    func card(_ windowID: WindowID, x: Double, column: Int) -> OverviewWindowProjection {
      OverviewWindowProjection(
        windowID: windowID,
        frame: Rect(x: x, y: 0, width: 100, height: 100),
        layer: .tiled(columnIndex: column, windowIndex: 0),
        isNativeFullscreen: false,
        canDrag: true
      )
    }
    func projection(_ windows: [OverviewWindowProjection]) -> OverviewProjection {
      OverviewProjection(
        monitorID: monitorID,
        workspaces: [
          OverviewWorkspaceProjection(
            workspaceID: workspaceID,
            frame: monitorFrame,
            windows: windows
          )
        ]
      )
    }
    let source = projection([
      card(first, x: 0, column: 0),
      card(second, x: 100, column: 1),
    ])
    let target = projection([
      card(second, x: 0, column: 0),
      card(first, x: 100, column: 1),
    ])

    let middle = interpolateOverviewProjection(from: source, to: target, progress: 0.5)
    let windows = try #require(middle.workspaces.first?.windows)
    let movedFirst = try #require(windows.first(where: { $0.windowID == first }))
    let movedSecond = try #require(windows.first(where: { $0.windowID == second }))

    #expect(movedFirst.frame.x == 50)
    #expect(movedSecond.frame.x == 50)
    #expect(movedFirst.layer == .tiled(columnIndex: 1, windowIndex: 0))

    let returning = interpolateOverviewProjection(
      from: target,
      to: source,
      progress: 0.5,
      foregroundWindowID: first
    )
    #expect(
      returning.hitTest(OverviewPoint(x: 50, y: 50))
        == .window(windowID: first, monitorID: monitorID, workspaceID: workspaceID)
    )
  }

  @Test
  func `Projection interpolation follows a window between workspaces`() throws {
    let firstWorkspace = WorkspaceID(rawValue: "1")
    let secondWorkspace = WorkspaceID(rawValue: "2")
    let windowID = WindowID(rawValue: 1)
    let card = OverviewWindowProjection(
      windowID: windowID,
      frame: Rect(x: 0, y: 0, width: 100, height: 100),
      layer: .tiled(columnIndex: 0, windowIndex: 0),
      isNativeFullscreen: false,
      canDrag: true
    )
    let source = OverviewProjection(
      monitorID: monitorID,
      workspaces: [
        OverviewWorkspaceProjection(
          workspaceID: firstWorkspace,
          frame: Rect(x: 0, y: 0, width: 100, height: 100),
          windows: [card]
        ),
        OverviewWorkspaceProjection(
          workspaceID: secondWorkspace,
          frame: Rect(x: 0, y: 100, width: 100, height: 100),
          windows: []
        ),
      ]
    )
    let target = OverviewProjection(
      monitorID: monitorID,
      workspaces: [
        OverviewWorkspaceProjection(
          workspaceID: firstWorkspace,
          frame: Rect(x: 0, y: 0, width: 100, height: 100),
          windows: []
        ),
        OverviewWorkspaceProjection(
          workspaceID: secondWorkspace,
          frame: Rect(x: 0, y: 100, width: 100, height: 100),
          windows: [
            OverviewWindowProjection(
              windowID: windowID,
              frame: Rect(x: 0, y: 100, width: 100, height: 100),
              layer: card.layer,
              isNativeFullscreen: false,
              canDrag: true
            )
          ]
        ),
      ]
    )

    let middle = interpolateOverviewProjection(
      from: source,
      to: target,
      progress: 0.5,
      foregroundWindowID: windowID
    )
    let start = interpolateOverviewProjection(
      from: source,
      to: target,
      progress: 0,
      foregroundWindowID: windowID
    )

    #expect(middle.workspaces[1].windows[0].frame.y == 50)
    #expect(
      start.hitTest(OverviewPoint(x: 50, y: 50))
        == .window(
          windowID: windowID,
          monitorID: monitorID,
          workspaceID: secondWorkspace
        )
    )
  }

  @Test
  func `Drop target distinguishes stacks and new columns`() {
    let first = WindowID(rawValue: 1)
    let second = WindowID(rawValue: 2)
    let workspace = Workspace(
      id: WorkspaceID(rawValue: "1"),
      columns: [
        Column(windows: [first, second], focusedWindow: 0, width: .fraction(0.5))
      ]
    )
    var windows = Dictionary(uniqueKeysWithValues: [first, second].map { id in
      (id, Window(id: id, appID: "app", title: "window", frame: monitorFrame))
    })
    windows[first] = Window(
      id: first,
      appID: "app",
      title: "window",
      frame: monitorFrame,
      floating: true,
      forceTiling: true
    )
    let snapshot = OverviewSnapshot(
      monitors: [Monitor(id: monitorID, workspaces: [workspace], activeWorkspace: workspace.id)],
      monitorFrames: [monitorID: monitorFrame],
      windows: windows
    )
    let projection = projectOverview(
      snapshot: snapshot,
      monitorID: monitorID,
      bounds: monitorFrame,
      viewport: OverviewViewport(),
      layout: LayoutSettings()
    )
    let firstCard = projection.workspaces[0].windows[0].frame
    let card = projection.workspaces[0].frame

    #expect(
      overviewDropTarget(
        at: OverviewPoint(
          x: firstCard.x + firstCard.width / 2,
          y: firstCard.y + firstCard.height - 1
        ),
        sourceWindowID: first,
        projection: projection,
        snapshot: snapshot
      ) == .stack(
        monitorID: monitorID,
        workspaceID: workspace.id,
        columnIndex: 0,
        windowIndex: 1
      )
    )
    #expect(
      overviewDropTarget(
        at: OverviewPoint(
          x: firstCard.x + firstCard.width * 0.2,
          y: firstCard.y + firstCard.height / 2
        ),
        sourceWindowID: first,
        projection: projection,
        snapshot: snapshot
      ) == .newColumn(
        monitorID: monitorID,
        workspaceID: workspace.id,
        columnIndex: 0
      )
    )
    #expect(
      overviewDropTarget(
        at: OverviewPoint(
          x: firstCard.x + firstCard.width * 0.8,
          y: firstCard.y + firstCard.height / 2
        ),
        sourceWindowID: first,
        projection: projection,
        snapshot: snapshot
      ) == .newColumn(
        monitorID: monitorID,
        workspaceID: workspace.id,
        columnIndex: 1
      )
    )
    #expect(
      overviewDropTarget(
        at: OverviewPoint(x: card.x + card.width - 1, y: card.y + 1),
        sourceWindowID: first,
        projection: projection,
        snapshot: snapshot
      ) == .newColumn(
        monitorID: monitorID,
        workspaceID: workspace.id,
        columnIndex: 1
      )
    )
  }
}
