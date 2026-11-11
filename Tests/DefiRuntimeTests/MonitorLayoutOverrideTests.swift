import DefiConfig
import DefiCore
import DefiModel
import DefiRuntime
import Testing

struct MonitorLayoutOverrideTests {
  let laptopID = MonitorID(rawValue: 1)
  let wideID = MonitorID(rawValue: 2)
  let frames: [MonitorID: Rect] = [
    MonitorID(rawValue: 1): Rect(x: 0, y: 0, width: 1_000, height: 800),
    MonitorID(rawValue: 2): Rect(x: 1_000, y: 0, width: 3_000, height: 1_000),
  ]

  func config(_ wide: MonitorLayoutConfig? = MonitorLayoutConfig(
    defaultColumnWidth: 0.4, presetColumnWidths: [0.25, 0.4, 0.6]
  )) -> Config {
    Config(layout: LayoutConfig(monitors: wide.map { ["DELL U3818DW": $0] } ?? [:]))
  }

  func state(_ config: Config, names: [MonitorID: String]? = nil) -> RuntimeState {
    var state = RuntimeState(config: config)
    state.attachMonitor(laptopID)
    state.attachMonitor(wideID)
    state.retainMonitors(
      [laptopID, wideID], names: names ?? [laptopID: "Built-in Retina Display", wideID: "dell u3818dw"])
    return state
  }

  func open(_ rawID: UInt64, on monitorID: MonitorID, config: Config, state: inout RuntimeState) {
    let window = Window(
      id: WindowID(rawValue: rawID), appID: "app", title: "\(rawID)",
      frame: Rect(x: 0, y: 0, width: 500, height: 700), monitorID: monitorID)
    _ = reconcileWindows(Array(state.windows.values) + [window], config: config, state: &state)
  }

  func width(of rawID: UInt64, in state: RuntimeState) -> ColumnWidth? {
    state.monitors.flatMap(\.workspaces).flatMap(\.columns)
      .first { $0.windows.contains(WindowID(rawValue: rawID)) }?.width
  }

  @Test
  func `New windows open at the width of their display`() {
    let config = config()
    var state = state(config)
    open(1, on: wideID, config: config, state: &state)
    open(2, on: laptopID, config: config, state: &state)
    #expect(width(of: 1, in: state) == .fraction(0.4))
    #expect(width(of: 2, in: state) == .fraction(0.80))
  }

  @Test(arguments: [nil, [MonitorID(rawValue: 2): "LG UltraFine"]] as [[MonitorID: String]?])
  func `An unknown or unnamed display uses the global layout`(names: [MonitorID: String]?) {
    let config = config()
    var state = RuntimeState(config: config)
    state.attachMonitor(wideID)
    if let names { state.retainMonitors([wideID], names: names) }
    open(1, on: wideID, config: config, state: &state)
    #expect(width(of: 1, in: state) == .fraction(0.80))
    #expect(state.layout(on: wideID).presetColumnWidths == LayoutConfig().presetColumnWidths)
  }

  @Test
  func `Cycle width steps through the presets of the column's display`() throws {
    let config = config()
    var state = state(config)
    open(1, on: wideID, config: config, state: &state)
    try reduce(.cycleWidth(.next), on: wideID, state: &state, viewports: frames)
    #expect(width(of: 1, in: state) == .fraction(0.6))
    try reduce(.cycleWidth(.next), on: wideID, state: &state, viewports: frames)
    #expect(width(of: 1, in: state) == .fraction(0.25))
  }

  @Test
  func `A moved column keeps its width and then cycles through the new display's presets`() throws {
    let config = config()
    var state = state(config)
    open(1, on: laptopID, config: config, state: &state)
    try reduce(.moveColumnToMonitor(.right), on: laptopID, state: &state, monitorFrames: frames, viewports: frames)
    #expect(state.monitorID(containing: WindowID(rawValue: 1)) == wideID)
    #expect(width(of: 1, in: state) == .fraction(0.80))
    try reduce(.cycleWidth(.next), on: wideID, state: &state, viewports: frames)
    #expect(width(of: 1, in: state) == .fraction(0.25))
  }

  @Test
  func `A workspace that migrates after a disconnection uses its new display's layout`() {
    let config = config()
    var state = state(config)
    state.retainMonitors([wideID])
    open(1, on: wideID, config: config, state: &state)
    #expect(width(of: 1, in: state) == .fraction(0.4))
  }

  @Test
  func `Reloading the configuration changes new columns only`() {
    var state = state(config())
    open(1, on: wideID, config: config(), state: &state)
    let reloaded = config(MonitorLayoutConfig(defaultColumnWidth: 0.5))
    state.applyConfiguration(reloaded)
    open(2, on: wideID, config: reloaded, state: &state)
    #expect(width(of: 1, in: state) == .fraction(0.4))
    #expect(width(of: 2, in: state) == .fraction(0.5))
    #expect(state.layout(on: wideID).presetColumnWidths == LayoutConfig().presetColumnWidths)

    state.applyConfiguration(config(nil))
    open(3, on: wideID, config: config(nil), state: &state)
    #expect(width(of: 3, in: state) == .fraction(0.80))
  }

  @Test
  func `A restart keeps column widths and restores the override once displays report`() {
    let config = config()
    var state = state(config)
    open(1, on: wideID, config: config, state: &state)
    var restarted = RuntimeState(config: config, topology: state.topology)
    #expect(restarted.layout(on: wideID).defaultColumnWidth == 0.80)
    restarted.retainMonitors([laptopID, wideID], names: [wideID: "DELL U3818DW"])
    #expect(width(of: 1, in: restarted) == .fraction(0.4))
    #expect(restarted.layout(on: wideID) == state.layout(on: wideID))
  }
}
