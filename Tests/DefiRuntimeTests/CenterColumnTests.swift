import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct CenterColumnTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  private func makeState(
    columns: Int = 4, focusedColumn: Int = 0, centerFocusedColumn: CenterFocusedColumnConfig = .never
  ) -> RuntimeState {
    var state = RuntimeState(
      config: Config(layout: LayoutConfig(centerFocusedColumn: centerFocusedColumn, gaps: 0))
    )
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = (0..<columns).map {
      Column(window: WindowID(rawValue: UInt64($0 + 1)), width: .fraction(0.5))
    }
    state.monitors[0].workspaces[0].focusedColumn = focusedColumn
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    return state
  }

  private func centered(_ command: Command, in state: inout RuntimeState) throws {
    try reduce(command, on: monitorID, state: &state, viewports: [monitorID: viewport])
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
  }

  @Test
  func `Center column puts the first column in the middle in never mode`() throws {
    var state = makeState()
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0)

    try centered(.centerColumn, in: &state)

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == -0.25)
  }

  @Test
  func `Center column centers an inner column and keeps it through recomputation`() throws {
    var state = makeState(focusedColumn: 3)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 1.0)

    try centered(.centerColumn, in: &state)
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 1.25)
  }

  @Test
  func `Moving to another column drops the pin`() throws {
    var state = makeState()
    try centered(.centerColumn, in: &state)

    try centered(.focusColumn(.right), in: &state)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.0)
    #expect(state.monitors[0].workspaces[0].scrollFocus?.pinned == nil)

    try centered(.focusColumn(.left), in: &state)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.0)
  }

  @Test
  func `A second press changes nothing`() throws {
    var state = makeState()
    try centered(.centerColumn, in: &state)

    #expect(try changedState(after: .centerColumn, on: monitorID, from: state) == nil)
  }

  @Test
  func `Center column on an empty workspace changes nothing`() throws {
    let state = makeState(columns: 0)

    #expect(try changedState(after: .centerColumn, on: monitorID, from: state) == nil)
  }

  @Test
  func `Center column leaves a floating selection in the floating layer`() throws {
    var state = makeState()
    state.monitors[0].workspaces[0].floatingWindows = [WindowID(rawValue: 9)]
    state.monitors[0].workspaces[0].focusedLayer = .floating

    try centered(.centerColumn, in: &state)

    #expect(state.monitors[0].workspaces[0].focusedLayer == .floating)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == -0.25)
  }

  @Test
  func `Center column leaves a native fullscreen selection alone`() throws {
    var state = makeState()
    state.nativeFullscreenWindowIDs = [WindowID(rawValue: 1)]

    #expect(try changedState(after: .centerColumn, on: monitorID, from: state) == nil)
  }

  @Test
  func `The single-column setting centers a lone column and a second column ends it`() throws {
    var state = makeState(columns: 1)
    state.layout.alwaysCenterSingleColumn = true
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == -0.25)

    state.monitors[0].workspaces[0].columns.append(
      Column(window: WindowID(rawValue: 2), width: .fraction(0.5))
    )
    state.monitors[0].workspaces[0].focusedColumn = 1
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.0)
  }

  @Test
  func `Turning the single-column setting on moves the lone column from a config change`() {
    var state = makeState(columns: 1)
    #expect(state.monitors[0].workspaces[0].targetScrollOffset == 0.0)

    state.layout.alwaysCenterSingleColumn = true
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])

    #expect(state.monitors[0].workspaces[0].targetScrollOffset == -0.25)
  }

  @Test
  func `Reloading config with the single-column setting requests an immediate reflow`() {
    var state = makeState(columns: 1)

    let config = Config(layout: LayoutConfig(alwaysCenterSingleColumn: true))
    let firstReload = state.applyConfiguration(config)
    let secondReload = state.applyConfiguration(config)

    #expect(firstReload)
    #expect(!secondReload)
  }

  @Test
  func `Config maps the single-column setting into layout settings`() {
    let config = Config(layout: LayoutConfig(alwaysCenterSingleColumn: true))

    #expect(RuntimeState(config: config).layout.alwaysCenterSingleColumn)
    #expect(!RuntimeState(config: Config()).layout.alwaysCenterSingleColumn)
  }
}
