import DefiModel
import Testing

struct ModelTests {
  @Test
  func `Constructors use safe defaults`() {
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "app",
      title: "title",
      frame: Rect(x: 1, y: 2, width: 3, height: 4)
    )
    let column = Column(window: WindowID(rawValue: 1), width: .fraction(0.72))
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"))

    #expect(window.role == nil)
    #expect(window.processID == nil)
    #expect(window.floating == false)
    #expect(window.forceTiling == false)
    #expect(window.intrinsicSize == false)
    #expect(column.focusedWindow == 0)
    #expect(column.preMaximizedWidth == nil)
    #expect(workspace.focusedColumn == 0)
    #expect(workspace.columns.isEmpty)
    #expect(workspace.floatingWindows.isEmpty)
    #expect(workspace.kind == .named)
    #expect(workspace.name == "1")
  }

  @Test(arguments: [
    (Command.switchWorkspace(WorkspaceID(rawValue: "web")), true, false),
    (Command.moveWindowToWorkspace(WorkspaceID(rawValue: "web")), true, true),
    (Command.sendWindowToWorkspace(WorkspaceID(rawValue: "web")), false, true),
    (Command.focusColumn(.right), false, false),
    (Command.cycleWidth(.next), false, false),
  ])
  func `Workspace command behavior is explicit`(
    testCase: (command: Command, activatesWorkspace: Bool, movesWindow: Bool)
  ) {
    #expect(testCase.command.activatesWorkspace == testCase.activatesWorkspace)
    #expect(testCase.command.movesWindowBetweenWorkspaces == testCase.movesWindow)
  }

  @Test
  func `Sending a column does not follow it`() {
    #expect(Command.moveColumnToWorkspace(.named("web"), follow: true).followsWindowMove)
    #expect(!Command.moveColumnToWorkspace(.named("web"), follow: false).followsWindowMove)
  }

  @Test(arguments: [
    ("focus-column left", Command.focusColumn(.left)),
    ("focus-column first", Command.focusColumn(.first)),
    ("focus-window last", Command.focusWindow(.last)),
    ("move-column last", Command.moveColumn(.last)),
    ("move-window down", Command.moveWindow(.down)),
    ("move-column-to-monitor left", Command.moveColumnToMonitor(.left)),
    ("move-window-to-monitor up", Command.moveWindowToMonitor(.up)),
    ("focus-floating next", Command.focusFloating(.next)),
    ("workspace sim", Command.switchWorkspace(WorkspaceID(rawValue: "sim"))),
    ("focus-workspace down", Command.focusWorkspace(.relative(.down))),
    ("focus-workspace-position 4", Command.focusWorkspace(.position(4))),
    (
      "move-column-to-workspace up",
      Command.moveColumnToWorkspace(.relative(.up), follow: true)
    ),
    (
      "move-column-to-workspace-name up",
      Command.moveColumnToWorkspace(.named("up"), follow: true)
    ),
    (
      "move-window-to-workspace down",
      Command.moveWindowToWorkspaceTarget(.relative(.down), follow: true)
    ),
    (
      "send-window-to-workspace-position 3",
      Command.moveWindowToWorkspaceTarget(.position(3), follow: false)
    ),
    ("reorder-workspace down", Command.reorderWorkspace(.down)),
    ("move-workspace-to-monitor right", Command.moveWorkspaceToMonitor(.right)),
    ("focus-monitor left", Command.focusMonitor(.left)),
    ("maximize-column", Command.maximizeColumn),
    ("toggle-floating", Command.toggleFloating),
    ("activate-floating", Command.activateFloating),
    ("toggle-overview", Command.toggleOverview),
    ("toggle-cheatsheet", Command.toggleCheatsheet),
  ])
  func `Parses shared commands`(
    testCase: (input: String, expected: Command)
  ) throws {
    #expect(try parseCommand(testCase.input) == testCase.expected)
  }

  @Test(arguments: [
    ("move-window right", CommandParseError.invalidDirection("right")),
    ("move-column-to-monitor next", CommandParseError.invalidDirection("next")),
  ])
  func `Rejects invalid move directions`(
    testCase: (input: String, expectedError: CommandParseError)
  ) {
    #expect(throws: testCase.expectedError) {
      try parseCommand(testCase.input)
    }
  }

  @Test
  func `Rejects obsolete fullscreen command name`() {
    #expect(throws: CommandParseError.unknownCommand("toggle-fullscreen")) {
      try parseCommand("toggle-fullscreen")
    }
  }

  @Test(arguments: [
    (Command.cycleWidth(.next), true, false),
    (Command.maximizeColumn, true, false),
    (Command.joinWindow(.left), true, false),
    (Command.unjoinWindows, true, false),
    (Command.moveColumnToMonitor(.right), true, true),
    (Command.moveWindowToMonitor(.right), true, true),
    (Command.focusColumn(.right), false, false),
    (Command.toggleFloating, false, false),
    (Command.toggleOverview, false, false),
  ])
  func `Managed layout command behavior is explicit`(
    testCase: (command: Command, resizesLayout: Bool, crossesMonitors: Bool)
  ) {
    #expect(testCase.command.resizesManagedLayout == testCase.resizesLayout)
    #expect(
      testCase.command.movesWindowsAcrossMonitors == testCase.crossesMonitors)
  }

  @Test(arguments: [
    (Command.activateFloating, true),
    (Command.focusFloating(.next), true),
    (Command.toggleFloating, false),
  ])
  func `Floating focus behavior is explicit`(
    testCase: (command: Command, expected: Bool)
  ) {
    #expect(testCase.command.explicitlyFocusesFloating == testCase.expected)
  }
}
