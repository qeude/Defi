import DefiModel
import Testing

struct ModelTests {
  @Test(arguments: [
    ("focus-column left", Command.focusColumn(.left)),
    ("focus-column first", Command.focusColumn(.first)),
    ("focus-window last", Command.focusWindow(.last)),
    ("focus-window-or-workspace up", Command.focusWindowOrWorkspace(.up)),
    ("focus-window-or-workspace down", Command.focusWindowOrWorkspace(.down)),
    ("move-column last", Command.moveColumn(.last)),
    ("move-window down", Command.moveWindow(.down)),
    ("consume-or-expel-window left", Command.consumeOrExpelWindow(.left)),
    ("swap-window right", Command.swapWindow(.right)),
    ("move-column-to-monitor left", Command.moveColumnToMonitor(.left)),
    ("move-window-to-monitor up", Command.moveWindowToMonitor(.up)),
    ("focus-column-or-monitor left", Command.focusColumnOrMonitor(.left)),
    ("move-column-or-to-monitor right", Command.moveColumnOrToMonitor(.right)),
    ("focus-floating next", Command.focusFloating(.next)),
    ("workspace sim", Command.switchWorkspace(WorkspaceID(rawValue: "sim"))),
    ("focus-workspace down", Command.focusWorkspace(.relative(.down))),
    ("focus-workspace-position 4", Command.focusWorkspace(.position(4))),
    ("focus-workspace-previous", Command.focusWorkspace(.lastActive)),
    ("focus-window-previous", Command.focusWindowPrevious),
    ("recent-windows next", Command.recentWindows(.next)),
    ("recent-windows prev", Command.recentWindows(.previous)),
    ("recent-windows confirm", Command.recentWindows(.confirm)),
    ("recent-windows cancel", Command.recentWindows(.cancel)),
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
    ("set-column-width +5%", Command.setColumnWidth(.adjust(.fraction(0.05)))),
    ("set-column-width -10%", Command.setColumnWidth(.adjust(.fraction(-0.1)))),
    ("set-column-width 60%", Command.setColumnWidth(.set(.fraction(0.6)))),
    ("set-column-width 960", Command.setColumnWidth(.set(.pixels(960)))),
    ("set-column-width -40", Command.setColumnWidth(.adjust(.pixels(-40)))),
    ("expand-column-to-available-width", Command.expandColumnToAvailableWidth),
    ("center-column", Command.centerColumn),
    ("center-visible-columns", Command.centerVisibleColumns),
    ("toggle-floating", Command.toggleFloating),
    ("activate-floating", Command.activateFloating),
    ("toggle-overview", Command.toggleOverview),
    ("toggle-cheatsheet", Command.toggleCheatsheet),
    ("open-settings", Command.openSettings),
    ("focus-window-id 42", Command.focusWindowID(WindowID(rawValue: 42))),
    ("set-window-height 40%", Command.setWindowHeight(.share(0.4))),
    ("set-window-height +10%", Command.setWindowHeight(.adjust(0.1))),
    ("set-window-height -5%", Command.setWindowHeight(.adjust(-0.05))),
    ("set-window-height 420", Command.setWindowHeight(.points(420))),
    ("reset-window-height", Command.resetWindowHeight),
    ("switch-preset-window-height", Command.switchPresetWindowHeight),
  ])
  func `Parses shared commands`(
    testCase: (input: String, expected: Command)
  ) throws {
    #expect(try parseCommand(testCase.input) == testCase.expected)
  }

  @Test(arguments: [
    ("move-window right", CommandParseError.invalidDirection("right")),
    ("consume-or-expel-window next", .invalidDirection("next")),
    ("swap-window up", .invalidDirection("up")),
    ("move-column-to-monitor next", .invalidDirection("next")),
    ("focus-window-or-workspace next", .invalidDirection("next")),
    ("recent-windows left", .invalidDirection("left")),
    ("focus-column-or-monitor up", .invalidDirection("up")),
    ("move-column-or-to-monitor first", .invalidDirection("first")),
    ("focus-window-or-workspace", .missingArgument("direction")),
    ("toggle-fullscreen", .unknownCommand("toggle-fullscreen")),
    ("set-column-width", .missingArgument("width")),
    ("set-column-width 0", .invalidWidth("0")),
    ("set-column-width 0%", .invalidWidth("0%")),
    ("set-column-width wide", .invalidWidth("wide")),
    ("set-column-width +-5%", .invalidWidth("+-5%")),
    ("set-column-width 1e3", .invalidWidth("1e3")),
    ("set-column-width inf", .invalidWidth("inf")),
    ("focus-window-id safari", .invalidWindowID("safari")),
    ("set-window-height", .missingArgument("height")),
    ("set-window-height 0%", .invalidHeight("0%")),
    ("set-window-height 150%", .invalidHeight("150%")),
    ("set-window-height -300", .invalidHeight("-300")),
    ("set-window-height +-5%", .invalidHeight("+-5%")),
    ("set-window-height tall", .invalidHeight("tall")),
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
  func `The composite focus command is stateless until resolved`() {
    let command = Command.focusWindowOrWorkspace(.down)
    #expect(!command.activatesWorkspace)
    #expect(!command.movesWindowBetweenWorkspaces)
    #expect(!command.movesWindowsAcrossMonitors)
    #expect(!command.explicitlyFocusesFloating)
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
    (Command.setColumnWidth(.set(.fraction(0.5))), true),
    (Command.expandColumnToAvailableWidth, true),
    (Command.setWindowHeight(.adjust(0.1)), true),
    (Command.resetWindowHeight, true),
    (Command.centerColumn, false),
    (Command.centerVisibleColumns, false),
    (Command.focusWindowOrWorkspace(.down), false),
    (Command.focusWorkspace(.lastActive), false),
    (Command.toggleFloating, true),
    (Command.joinWindow(.left), true),
    (Command.unjoinWindows, true),
    (Command.consumeOrExpelWindow(.left), true),
    (Command.swapWindow(.right), true),
    (Command.focusColumn(.right), false),
    (Command.toggleOverview, false),
  ])
  func selectedLayoutEditsAnimate(testCase: (command: Command, expected: Bool)) {
    #expect(testCase.command.editsSelectedLayout == testCase.expected)
    #expect(testCase.command.animatesManagedLayout == testCase.expected)
  }
}
