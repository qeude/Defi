import DefiConfig
import DefiCore
import DefiModel
import Foundation
import Testing

@testable import DefiRuntime

struct FullscreenWindowTests {
  let monitorID = MonitorID(rawValue: 1)
  let viewport = Rect(x: 0, y: 25, width: 1_000, height: 775)

  func makeState(_ columns: [[UInt64]], focused: Int, focusedWindow: Int = 0) -> RuntimeState {
    var state = RuntimeState(config: Config())
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = columns.map { ids in
      for id in ids {
        state.windows[WindowID(rawValue: id)] = Window(
          id: WindowID(rawValue: id), appID: "app", title: "\(id)",
          frame: Rect(x: 0, y: 0, width: 400, height: 700))
      }
      return Column(
        windows: ids.map(WindowID.init(rawValue:)), focusedWindow: 0, width: .fraction(0.5))
    }
    state.monitors[0].workspaces[0].focusedColumn = focused
    state.monitors[0].workspaces[0].columns[focused].focusedWindow = focusedWindow
    state.maintainWorkspaceLifecycle()
    settle(&state)
    return state
  }

  /// Runs a command as the daemon does, and lets the scroll animation finish.
  func run(_ command: Command, _ state: inout RuntimeState) throws {
    try reduce(command, on: monitorID, state: &state, viewports: [monitorID: viewport])
    settle(&state)
  }

  func settle(_ state: inout RuntimeState) {
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    state.monitors[0].workspaces[0].scrollOffset = state.monitors[0].workspaces[0].targetScrollOffset
  }

  var workspace: (RuntimeState) -> Workspace { { $0.monitors[0].workspaces[0] } }

  func frame(_ id: UInt64, _ state: RuntimeState) -> Rect? {
    computeLayout(
      workspace: workspace(state), viewport: viewport, windows: Array(state.windows.values),
      settings: state.layout
    ).first { $0.windowID == WindowID(rawValue: id) }?.frame
  }

  func onScreen(_ frame: Rect?) -> Bool {
    guard let frame else { return false }
    return frame.x < viewport.x + viewport.width && frame.x + frame.width > viewport.x
  }

  @Test
  func `Fullscreen covers the viewport without gaps and leaving restores width and view`() throws {
    var state = makeState([[1], [2], [3]], focused: 1)
    let before = (offset: workspace(state).targetScrollOffset, frame: frame(2, state))

    try run(.fullscreenWindow, &state)
    #expect(workspace(state).columns[1].isFullscreen)
    #expect(workspace(state).columns[1].width == .fraction(0.5))
    #expect(frame(2, state) == viewport)
    #expect(!onScreen(frame(1, state)) && !onScreen(frame(3, state)))

    try run(.fullscreenWindow, &state)
    #expect(!workspace(state).columns[1].isFullscreen)
    #expect(workspace(state).targetScrollOffset == before.offset)
    #expect(frame(2, state) == before.frame)
  }

  @Test
  func `A stacked window leaves its stack and stays in its own column afterwards`() throws {
    var state = makeState([[1, 2, 3], [4]], focused: 0, focusedWindow: 1)
    state.monitors[0].workspaces[0].columns[0].windowHeights = [
      WindowID(rawValue: 1): 0.5, WindowID(rawValue: 2): 0.3, WindowID(rawValue: 3): 0.2,
    ]

    try run(.fullscreenWindow, &state)
    #expect(workspace(state).columns.map { $0.windows.map(\.rawValue) } == [[1, 3], [2], [4]])
    #expect(workspace(state).focusedColumn == 1 && workspace(state).columns[1].isFullscreen)
    #expect(workspace(state).columns[0].windowHeights?[WindowID(rawValue: 2)] == nil)
    #expect(frame(2, state) == viewport)

    try run(.fullscreenWindow, &state)
    #expect(workspace(state).columns.map { $0.windows.map(\.rawValue) } == [[1, 3], [2], [4]])
    #expect(!workspace(state).columns[1].isFullscreen)
  }

  @Test
  func `Moving focus away keeps fullscreen in place and forgets the view to restore`() throws {
    var state = makeState([[1], [2], [3]], focused: 1)
    let before = workspace(state).targetScrollOffset
    try run(.fullscreenWindow, &state)
    let fullscreenOffset = workspace(state).targetScrollOffset
    #expect(fullscreenOffset != before)

    try run(.focusColumn(.left), &state)
    #expect(workspace(state).columns[1].isFullscreen)
    #expect(frame(2, state)?.width == viewport.width)
    try run(.focusColumn(.right), &state)
    #expect(workspace(state).scrollFocus?.fullscreenRestoreOffset == nil)

    try run(.fullscreenWindow, &state)
    #expect(!workspace(state).columns[1].isFullscreen)
    #expect(workspace(state).targetScrollOffset == fullscreenOffset)
  }

  @Test(arguments: [Command.maximizeColumn, .cycleWidth(.next), .setColumnWidth(.set(.fraction(0.6)))])
  func `A width command leaves fullscreen and applies`(command: Command) throws {
    var state = makeState([[1], [2]], focused: 0)
    try run(.fullscreenWindow, &state)
    try run(command, &state)
    #expect(!workspace(state).columns[0].isFullscreen)
    #expect(workspace(state).columns[0].width != .fraction(0.5))
  }

  @Test
  func `Stacking a window into a fullscreen column ends fullscreen`() throws {
    var state = makeState([[1], [2]], focused: 1)
    try run(.fullscreenWindow, &state)
    try run(.focusColumn(.left), &state)
    try run(.joinWindow(.right), &state)
    #expect(workspace(state).columns.count == 1)
    #expect(workspace(state).columns[0].fullscreen == nil)
  }

  @Test
  func `A floating selection, or a native fullscreen one, is left alone`() throws {
    var state = makeState([[1]], focused: 0)
    state.monitors[0].workspaces[0].focusedLayer = .floating
    try run(.fullscreenWindow, &state)
    #expect(!workspace(state).columns[0].isFullscreen)

    state.monitors[0].workspaces[0].focusedLayer = .tiled
    reconcileWindows(
      Array(state.windows.values), config: Config(),
      nativeFullscreenWindowIDs: [WindowID(rawValue: 1)], state: &state)
    try run(.fullscreenWindow, &state)
    #expect(!workspace(state).columns[0].isFullscreen)
  }

  @Test
  func `Native fullscreen replaces it, and the window returns as an ordinary column`() throws {
    var state = makeState([[1], [2]], focused: 0)
    try run(.fullscreenWindow, &state)
    let windows = Array(state.windows.values)
    reconcileWindows(
      windows, config: Config(), nativeFullscreenWindowIDs: [WindowID(rawValue: 1)], state: &state)
    reconcileWindows(windows, config: Config(), state: &state)
    let column = try #require(workspace(state).columns.first { $0.windows == [WindowID(rawValue: 1)] })
    #expect(!column.isFullscreen)
    #expect(column.width == .fraction(0.5))
  }

  @Test
  func `A native resize of a fullscreen window never becomes its column width`() throws {
    var state = makeState([[1], [2]], focused: 0)
    try run(.fullscreenWindow, &state)
    var refused = viewport
    refused.width -= 200
    #expect(!learnTiledWindowWidth(
      WindowID(rawValue: 1), actualFrame: refused, state: &state, viewports: [monitorID: viewport]))
    #expect(workspace(state).columns[0].width == .fraction(0.5))
  }

  @Test
  func `Fullscreen and the view to restore survive a restart`() throws {
    var state = makeState([[1], [2]], focused: 1)
    try run(.fullscreenWindow, &state)
    let restored = RuntimeState(
      config: Config(),
      topology: try JSONDecoder().decode(
        WorkspaceTopology.self, from: JSONEncoder().encode(state.topology)))
    #expect(restored.monitors[0].workspaces[0].columns[1].isFullscreen)
    #expect(restored.monitors[0].workspaces[0].scrollFocus?.fullscreenRestoreOffset == 0)
  }
}
