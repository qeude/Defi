public enum CheatsheetInput: Equatable, Sendable {
  case modifiersChanged(matches: Bool, released: Bool)
  case keyDown(modifiersHeld: Bool)
  case holdElapsed
  case toggle
  case dismiss
}
