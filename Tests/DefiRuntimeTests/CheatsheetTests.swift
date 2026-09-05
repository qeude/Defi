import DefiConfig
import DefiModel
import DefiRuntime
import Foundation
import Testing

struct CheatsheetTests {
  @Test
  func `Hold cancellation and shortcut dismissal cannot reopen until release`() {
    var state = CheatsheetState()
    state.handle(.keyDown(modifiersHeld: false), holdEnabled: true)
    state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: true)
    #expect(state.holdPending && !state.isVisible)
    state.handle(.keyDown(modifiersHeld: true), holdEnabled: true)
    state.handle(.holdElapsed, holdEnabled: true)
    #expect(!state.isVisible)
    state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: true)
    #expect(!state.holdPending)
    state.handle(.modifiersChanged(matches: false, released: true), holdEnabled: true)
    state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: true)
    state.handle(.holdElapsed, holdEnabled: true)
    #expect(state.isVisible)
    state.handle(.dismiss, holdEnabled: true)
    state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: true)
    state.handle(.holdElapsed, holdEnabled: true)
    #expect(!state.isVisible && !state.holdPending)
  }

  @Test
  func `Release cancels a short hold and closes a long hold`() {
    for elapsed in [false, true] {
      var state = CheatsheetState()
      state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: true)
      if elapsed { state.handle(.holdElapsed, holdEnabled: true) }
      #expect(state.isVisible == elapsed)
      state.handle(.modifiersChanged(matches: false, released: true), holdEnabled: true)
      state.handle(.holdElapsed, holdEnabled: true)
      #expect(!state.isVisible && !state.holdPending)
    }
  }

  @Test(arguments: [true, false])
  func `Toggle works independently of hold and survives modifier release`(holdEnabled: Bool) throws {
    let config = try Config.decode(Data("""
      show_cheatsheet_on_modifier_hold = \(holdEnabled)
      [keys]
      alt-slash = "toggle-cheatsheet"
      """.utf8))
    #expect(config.showCheatsheetOnModifierHold == holdEnabled)
    let command = try #require(config.keys["alt-slash"])
    #expect(try parseCommand(command) == .toggleCheatsheet)
    var state = CheatsheetState()
    state.handle(.modifiersChanged(matches: true, released: false), holdEnabled: holdEnabled)
    #expect(state.holdPending == holdEnabled)
    state.handle(.keyDown(modifiersHeld: true), holdEnabled: holdEnabled)
    state.handle(.toggle, holdEnabled: holdEnabled)
    state.handle(.modifiersChanged(matches: false, released: true), holdEnabled: holdEnabled)
    state.handle(.holdElapsed, holdEnabled: holdEnabled)
    #expect(state.isVisible && !state.holdPending)
    state.handle(.toggle, holdEnabled: holdEnabled)
    #expect(!state.isVisible)
    state.handle(.toggle, holdEnabled: holdEnabled)
    state.handle(.dismiss, holdEnabled: holdEnabled)
    #expect(!state.isVisible)
  }
}
