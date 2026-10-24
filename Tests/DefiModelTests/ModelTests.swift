import DefiModel
import Testing

struct ModelTests {
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
    ("move-column-to-monitor next", .invalidDirection("next")),
    ("toggle-fullscreen", .unknownCommand("toggle-fullscreen")),
  ])
  func `Rejects invalid directions and obsolete commands`(input: String, error: CommandParseError) {
    #expect(throws: error) { try parseCommand(input) }
  }

  @Test
  func `Single-window activation fallback is unambiguous`() {
    let frame = Rect(x: 0, y: 0, width: 10, height: 10)
    let solo = Window(
      id: WindowID(rawValue: 1), appID: "a", title: "solo",
      frame: frame, processID: 42
    )
    let other = Window(
      id: WindowID(rawValue: 2), appID: "b", title: "other",
      frame: frame, processID: 43
    )
    let sibling = Window(
      id: WindowID(rawValue: 3), appID: "a", title: "sibling",
      frame: frame, processID: 42
    )
    #expect(singleManagedWindowID(processID: 42, in: [solo, other]) == solo.id)
    #expect(singleManagedWindowID(processID: 42, in: [solo, sibling, other]) == nil)
    #expect(singleManagedWindowID(processID: 99, in: [solo, other]) == nil)
    #expect(singleManagedWindowID(processID: nil, in: [solo]) == nil)
    #expect(singleManagedWindowID(processID: 42, in: []) == nil)
  }

  @Test
  func `Sending a column does not follow it`() {
    #expect(Command.moveColumnToWorkspace(.named("web"), follow: true).followsWindowMove)
    #expect(!Command.moveColumnToWorkspace(.named("web"), follow: false).followsWindowMove)
  }

  @Test(arguments: [
    (Command.moveColumn(.right), true),
    (Command.moveWindow(.down), true),
    (Command.cycleWidth(.next), true),
    (Command.maximizeColumn, true),
    (Command.toggleFloating, true),
    (Command.joinWindow(.left), true),
    (Command.unjoinWindows, true),
    (Command.focusColumn(.right), false),
    (Command.toggleOverview, false),
  ])
  func selectedLayoutEditsAnimate(testCase: (command: Command, expected: Bool)) {
    #expect(testCase.command.editsSelectedLayout == testCase.expected)
    #expect(testCase.command.animatesManagedLayout == testCase.expected)
  }
}
