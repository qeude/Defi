import DefiModel
import XCTest

final class ModelTests: XCTestCase {
  func testConstructorsUseSafeDefaults() {
    let window = Window(
      id: WindowID(rawValue: 1),
      appID: "app",
      title: "title",
      frame: Rect(x: 1, y: 2, width: 3, height: 4)
    )
    let column = Column(window: WindowID(rawValue: 1), width: .fraction(0.72))
    let workspace = Workspace(id: WorkspaceID(rawValue: "1"))

    XCTAssertNil(window.role)
    XCTAssertNil(window.processID)
    XCTAssertFalse(window.floating)
    XCTAssertFalse(window.forceTiling)
    XCTAssertFalse(window.intrinsicSize)
    XCTAssertEqual(column.focusedWindow, 0)
    XCTAssertNil(column.fullscreenPreviousWidth)
    XCTAssertEqual(workspace.focusedColumn, 0)
    XCTAssertTrue(workspace.columns.isEmpty)
    XCTAssertTrue(workspace.floatingWindows.isEmpty)
  }

  func testOnlyFollowingWorkspaceCommandsActivateWorkspace() {
    XCTAssertTrue(
      Command.switchWorkspace(WorkspaceID(rawValue: "web")).activatesWorkspace
    )
    XCTAssertTrue(
      Command.moveWindowToWorkspace(WorkspaceID(rawValue: "web")).activatesWorkspace
    )
    XCTAssertFalse(
      Command.sendWindowToWorkspace(WorkspaceID(rawValue: "web")).activatesWorkspace
    )
    XCTAssertFalse(Command.focusColumn(.right).activatesWorkspace)
    XCTAssertFalse(Command.cycleWidth(.next).activatesWorkspace)
  }

  func testParsesSharedCommands() throws {
    XCTAssertEqual(try parseCommand("focus-column left"), .focusColumn(.left))
    XCTAssertEqual(try parseCommand("focus-column first"), .focusColumn(.first))
    XCTAssertEqual(try parseCommand("focus-window last"), .focusWindow(.last))
    XCTAssertEqual(try parseCommand("move-column last"), .moveColumn(.last))
    XCTAssertEqual(try parseCommand("move-window down"), .moveWindow(.down))
    XCTAssertEqual(try parseCommand("focus-floating next"), .focusFloating(.next))
    XCTAssertEqual(
      try parseCommand("workspace sim"),
      .switchWorkspace(WorkspaceID(rawValue: "sim"))
    )
    XCTAssertEqual(try parseCommand("toggle-fullscreen"), .toggleFullscreen)
    XCTAssertEqual(try parseCommand("toggle-floating"), .toggleFloating)
    XCTAssertEqual(try parseCommand("activate-floating"), .activateFloating)
  }

  func testRejectsInvalidMoveDirection() {
    XCTAssertThrowsError(try parseCommand("move-window right")) { error in
      XCTAssertEqual(error as? CommandParseError, .invalidDirection("right"))
    }
  }

  func testManagedLayoutResizeCommandsAreExplicit() {
    XCTAssertTrue(Command.cycleWidth(.next).resizesManagedLayout)
    XCTAssertTrue(Command.toggleFullscreen.resizesManagedLayout)
    XCTAssertFalse(Command.focusColumn(.right).resizesManagedLayout)
    XCTAssertFalse(Command.toggleFloating.resizesManagedLayout)
  }

  func testFloatingFocusCommandsRequestExplicitFocus() {
    XCTAssertTrue(Command.activateFloating.explicitlyFocusesFloating)
    XCTAssertTrue(Command.focusFloating(.next).explicitlyFocusesFloating)
    XCTAssertFalse(Command.toggleFloating.explicitlyFocusesFloating)
  }
}
