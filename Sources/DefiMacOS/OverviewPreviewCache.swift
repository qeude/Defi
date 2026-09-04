import AppKit
import DefiModel

private struct RememberedOverviewPreview {
  let image: NSImage
  let appID: String
  let processID: pid_t
}

@MainActor
final class OverviewPreviewCache {
  private var entries: [WindowID: RememberedOverviewPreview] = [:]
  private var byteCosts: [WindowID: Int] = [:]
  private let maximumBytes: Int
  var byteCount: Int { byteCosts.values.reduce(0, +) }
  var images: [WindowID: NSImage] { entries.mapValues(\.image) }

  init(maximumBytes: Int = 32 * 1_024 * 1_024) {
    self.maximumBytes = maximumBytes
  }

  func store(_ image: NSImage, byteCost: Int, for window: Window) {
    remove(window.id)
    guard let processID = window.processID,
      overviewPreviewCacheCanStore(
        windowID: window.id, byteCost: byteCost,
        currentByteCosts: byteCosts, maximumBytes: maximumBytes
      )
    else { return }
    entries[window.id] = RememberedOverviewPreview(
      image: image, appID: window.appID, processID: processID
    )
    byteCosts[window.id] = byteCost
  }

  func prune(windows: [WindowID: Window]) -> [WindowID] {
    let removed = entries.compactMap { windowID, entry in
      windows[windowID]?.appID == entry.appID
        && windows[windowID]?.processID == entry.processID ? nil : windowID
    }
    for windowID in removed { remove(windowID) }
    return removed
  }

  func remove(_ windowID: WindowID) {
    entries[windowID] = nil
    byteCosts[windowID] = nil
  }

  func removeAll() {
    entries.removeAll()
    byteCosts.removeAll()
  }
}
