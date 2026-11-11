import DefiModel

/// The recent windows switcher: a selection over the windows listed when it opened.
/// It changes no focus until `close` hands the selection to `focus-window-id`.
public struct RecentWindowsSwitcher: Equatable, Sendable {
  public private(set) var windowIDs: [WindowID] = []
  public private(set) var selection = 0

  public init() {}

  public var isOpen: Bool { !windowIDs.isEmpty }

  public var selectedWindowID: WindowID? {
    windowIDs.indices.contains(selection) ? windowIDs[selection] : nil
  }

  /// Opens on `state`'s windows, or moves the selection while open, wrapping. Opening
  /// forward selects the window `focus-window-previous` would focus, so a brief press
  /// goes back to it; opening backward selects the oldest.
  public mutating func step(forward: Bool, in state: RuntimeState) {
    guard isOpen else {
      windowIDs = state.recentWindowCandidates
      guard !windowIDs.isEmpty else { return }
      selection = forward
        ? state.previousFocusedWindowTarget.flatMap(windowIDs.firstIndex(of:)) ?? min(1, windowIDs.count - 1)
        : windowIDs.count - 1
      return
    }
    selection = (selection + (forward ? 1 : windowIDs.count - 1)) % windowIDs.count
  }

  /// Drops windows that left their workspace; a closed selection passes to the next window.
  public mutating func retainManagedWindows(in state: RuntimeState) {
    let locations = state.windowLocationMap()
    let before = windowIDs[..<min(selection, windowIDs.count)].filter { locations[$0] != nil }.count
    windowIDs.removeAll { locations[$0] == nil }
    selection = min(before, max(windowIDs.count - 1, 0))
  }

  /// Closes the switcher and returns the selected window.
  public mutating func close() -> WindowID? {
    defer { self = RecentWindowsSwitcher() }
    return selectedWindowID
  }
}
