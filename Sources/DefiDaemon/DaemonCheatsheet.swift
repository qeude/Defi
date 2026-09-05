import DefiMacOS
import DefiModel
import Foundation

@MainActor
extension Daemon {
  func handleCheatsheetInput(_ input: CheatsheetInput, monitorID: MonitorID? = nil) {
    let wasPending = cheatsheetState.holdPending
    let wasVisible = cheatsheetState.isVisible
    cheatsheetState.handle(
      desktopSessionActive ? input : .dismiss,
      holdEnabled: config.showCheatsheetOnModifierHold
    )
    if !cheatsheetState.holdPending {
      cheatsheetHoldTask?.cancel()
      cheatsheetHoldTask = nil
    } else if !wasPending {
      let inputTimestamp = platform.userInputTracker.latestEventTimestamp
      cheatsheetHoldTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(600)) }
        catch { return }
        guard !Task.isCancelled, let self else { return }
        // Input is recorded on the tap thread before its main-actor delivery.
        // Do not flash the panel if a newer key or release is already waiting.
        guard self.platform.userInputTracker.latestEventTimestamp == inputTimestamp else {
          self.handleCheatsheetInput(.keyDown(modifiersHeld: true))
          return
        }
        self.handleCheatsheetInput(.holdElapsed)
      }
    }
    guard wasVisible != cheatsheetState.isVisible else { return }
    hotKeys?.setCheatsheetVisible(cheatsheetState.isVisible)
    if cheatsheetState.isVisible {
      let controller = cheatsheetController ?? CheatsheetController(config: config)
      cheatsheetController = controller
      controller.show(on: monitorID ?? activeMonitorID ?? state.monitors.first?.id)
    } else {
      cheatsheetController?.close()
    }
  }
}
