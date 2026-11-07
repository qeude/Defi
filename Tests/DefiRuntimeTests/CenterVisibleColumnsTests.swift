import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct CenterVisibleColumnsTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let viewport = Rect(x: 0, y: 0, width: 1_000, height: 700)

  private func makeState(
    widths: [Double], focusedColumn: Int = 0,
    centerFocusedColumn: CenterFocusedColumnConfig = .never
  ) -> RuntimeState {
    var state = RuntimeState(
      config: Config(layout: LayoutConfig(centerFocusedColumn: centerFocusedColumn, gaps: 0))
    )
    state.attachMonitor(monitorID)
    state.monitors[0].workspaces[0].columns = widths.indices.map {
      Column(window: WindowID(rawValue: UInt64($0 + 1)), width: .fraction(widths[$0]))
    }
    state.monitors[0].workspaces[0].focusedColumn = focusedColumn
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
    return state
  }

  private func run(_ command: Command, in state: inout RuntimeState) throws {
    try reduce(command, on: monitorID, state: &state, viewports: [monitorID: viewport])
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])
  }

  private func unchanged(_ state: RuntimeState) throws -> Bool {
    try changedState(
      after: .centerVisibleColumns, on: monitorID, from: state, viewports: [monitorID: viewport]
    ) == nil
  }

  private func offset(_ state: RuntimeState) -> Double {
    state.monitors[0].workspaces[0].targetScrollOffset
  }

  @Test
  func `Two narrow columns at the left edge end up centered and stay there`() throws {
    var state = makeState(widths: [0.36, 0.36])
    #expect(offset(state) == 0)

    try run(.centerVisibleColumns, in: &state)
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])

    #expect(abs(offset(state) + 0.14) < 1e-9)
    #expect(try unchanged(state))
  }

  @Test
  func `Partially visible columns are left out of the group`() throws {
    var state = makeState(widths: [0.36, 0.36, 0.5])

    try run(.centerVisibleColumns, in: &state)

    #expect(abs(offset(state) + 0.14) < 1e-9)
  }

  @Test
  func `A group that fills the screen changes nothing`() throws {
    #expect(try unchanged(makeState(widths: [0.5, 0.5, 0.5])))
    #expect(try unchanged(makeState(widths: [1.2])))
  }

  @Test
  func `An empty workspace or a native fullscreen selection changes nothing`() throws {
    #expect(try unchanged(makeState(widths: [])))
    var state = makeState(widths: [0.36, 0.36])
    state.nativeFullscreenWindowIDs = [WindowID(rawValue: 1)]
    #expect(try unchanged(state))
  }

  @Test
  func `Selecting another column drops the hold`() throws {
    var state = makeState(widths: [0.36, 0.36])
    try run(.centerVisibleColumns, in: &state)

    try run(.focusColumn(.right), in: &state)

    #expect(state.monitors[0].workspaces[0].scrollFocus?.heldOffset == nil)
    #expect(offset(state) == 0)
  }

  @Test
  func `A wider column moves the strip only enough to keep it in view`() throws {
    var state = makeState(widths: [0.36, 0.36])
    try run(.centerVisibleColumns, in: &state)

    state.monitors[0].workspaces[0].columns[0].width = .fraction(0.9)
    synchronizeScrollOffsets(state: &state, viewports: [monitorID: viewport])

    #expect(abs(offset(state) + 0.1) < 1e-9)
  }

  @Test
  func `The group is centered under the always mode until selection leaves the column`() throws {
    var state = makeState(widths: [0.2, 0.3, 0.4], focusedColumn: 1, centerFocusedColumn: .always)
    #expect(abs(offset(state) + 0.15) < 1e-9)

    try run(.centerVisibleColumns, in: &state)
    #expect(abs(offset(state) + 0.25) < 1e-9)

    try run(.focusColumn(.left), in: &state)
    #expect(abs(offset(state) + 0.4) < 1e-9)
  }

  @Test
  func `A symmetric group under the always mode is already centered`() throws {
    #expect(try unchanged(makeState(widths: [0.2, 0.3, 0.2], focusedColumn: 1, centerFocusedColumn: .always)))
  }
}
