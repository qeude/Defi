import AppKit
import DefiModel

private struct RememberedOverviewPreview {
  let byteCost: Int
  let image: NSImage
  let appID: String
  let processID: pid_t
}

@MainActor
final class OverviewPreviewCache {
  private var entries: [WindowID: RememberedOverviewPreview] = [:]
  private let maximumBytes: Int
  var byteCount: Int { entries.values.reduce(0) { $0 + $1.byteCost } }
  var images: [WindowID: NSImage] { entries.mapValues(\.image) }

  init(maximumBytes: Int = 32 * 1_024 * 1_024) {
    self.maximumBytes = maximumBytes
  }

  func store(_ image: NSImage, byteCost: Int, for window: Window) {
    remove(window.id)
    guard let processID = window.processID,
      overviewPreviewCacheCanStore(
        windowID: window.id, byteCost: byteCost,
        currentByteCosts: entries.mapValues(\.byteCost), maximumBytes: maximumBytes
      )
    else { return }
    entries[window.id] = RememberedOverviewPreview(
      byteCost: byteCost, image: image, appID: window.appID, processID: processID
    )
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
  }

  func removeAll() {
    entries.removeAll()
  }
}
