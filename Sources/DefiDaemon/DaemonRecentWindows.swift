import DefiIPC
import DefiMacOS
import DefiModel
import DefiRuntime
import Foundation

@NavigationActor
extension Daemon {
  func handleRecentWindows(_ action: RecentWindowsAction) -> CommandResponse {
    switch action {
    case .next, .previous:
      guard !overviewState.isOpen else {
        return .failure("recent windows are unavailable while the Overview is open")
      }
      let opening = !recentWindows.isOpen
      recentWindows.step(forward: action == .next, in: state)
      guard recentWindows.isOpen else { return .failure("no managed window to switch to") }
      guard opening else {
        presentRecentWindows()
        return .success()
      }
      hotKeys?.setRecentWindowsOpen(true)
      recentWindowsMonitorID = activeMonitorID ?? state.monitors.first?.id
      // Like Niri's open delay: a brief press switches without drawing anything.
      recentWindowsShowTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let self, self.recentWindows.isOpen else { return }
        self.recentWindowsShowTask = nil
        self.recentWindowsVisible = true
        self.presentRecentWindows()
      }
      return .success()
    case .confirm:
      guard let windowID = closeRecentWindows() else { return .success() }
      return handle("focus-window-id \(windowID.rawValue)")
    case .cancel:
      closeRecentWindows()
      return .success()
    }
  }

  /// Closes the switcher without focusing anything and returns its selection.
  @discardableResult
  func closeRecentWindows() -> WindowID? {
    guard recentWindows.isOpen else { return nil }
    recentWindowsShowTask?.cancel()
    recentWindowsShowTask = nil
    hotKeys?.setRecentWindowsOpen(false)
    if recentWindowsVisible {
      recentWindowsVisible = false
      DispatchQueue.main.async { [self] in recentWindowsController?.close() }
    }
    return recentWindows.close()
  }

  /// Windows that close while the switcher is open leave it; the Overview closes it.
  func refreshRecentWindowsIfOpen() {
    guard recentWindows.isOpen else { return }
    recentWindows.retainManagedWindows(in: state)
    guard recentWindows.isOpen, !overviewState.isOpen else {
      closeRecentWindows()
      return
    }
    presentRecentWindows()
  }

  private func presentRecentWindows() {
    guard recentWindowsVisible else { return }
    let entries = recentWindows.windowIDs.map {
      RecentWindowsEntry(id: $0, title: state.windows[$0]?.title ?? "", processID: state.windows[$0]?.processID)
    }
    let (selection, monitorID, previews) =
      (recentWindows.selection, recentWindowsMonitorID, config.overview.windowPreviews)
    DispatchQueue.main.async { [self] in
      let controller = recentWindowsController ?? RecentWindowsController()
      recentWindowsController = controller
      controller.show(entries, selection: selection, on: monitorID, previews: previews)
    }
  }
}
