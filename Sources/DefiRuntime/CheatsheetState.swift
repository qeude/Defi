import DefiModel

public struct CheatsheetState: Equatable, Sendable {
  public private(set) var isVisible = false
  public private(set) var holdPending = false
  private var openedByHold = false
  private var blockedUntilRelease = false
  private var modifiersHeld = false

  public init() {}

  public mutating func handle(_ input: CheatsheetInput, holdEnabled: Bool) {
    switch input {
    case .modifiersChanged(let matches, let released):
      modifiersHeld = !released
      if released { blockedUntilRelease = false }
      if !matches {
        holdPending = false
        if openedByHold {
          isVisible = false
          openedByHold = false
        }
      } else if holdEnabled && !blockedUntilRelease && !isVisible {
        holdPending = true
      }
    case .keyDown(let modifiersHeld):
      self.modifiersHeld = modifiersHeld
      holdPending = false
      blockedUntilRelease = modifiersHeld
    case .holdElapsed:
      guard holdPending && holdEnabled else { return }
      holdPending = false
      isVisible = true
      openedByHold = true
    case .toggle:
      holdPending = false
      blockedUntilRelease = modifiersHeld
      isVisible.toggle()
      openedByHold = false
    case .dismiss:
      holdPending = false
      blockedUntilRelease = modifiersHeld
      isVisible = false
      openedByHold = false
    }
  }
}
