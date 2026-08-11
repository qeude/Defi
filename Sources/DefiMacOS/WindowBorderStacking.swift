import AppKit
import ApplicationServices
import CoreGraphics
import DefiModel
struct WindowBorderStackingRefreshRequest: Equatable, Sendable {
  let generation: UInt64
  let windowID: WindowID
}

struct WindowBorderStackingRefreshState {
  private var generation: UInt64 = 0

  mutating func request(
    for windowID: WindowID?
  ) -> WindowBorderStackingRefreshRequest? {
    generation &+= 1
    return windowID.map {
      WindowBorderStackingRefreshRequest(
        generation: generation,
        windowID: $0
      )
    }
  }

  func shouldApply(
    _ request: WindowBorderStackingRefreshRequest,
    activeWindowID: WindowID?
  ) -> Bool {
    request.generation == generation && request.windowID == activeWindowID
  }
}

struct WindowStackEntry: Equatable, Sendable {
  let windowID: WindowID
  let processID: pid_t
  let layer: Int
  let frame: Rect
}

struct WindowBorderStacking: Equatable, Sendable {
  let targetWindowID: WindowID?
  let activeWindowIsFrontmost: Bool
  let upperBoundWindowID: WindowID?
  let upperBoundLevel: Int?

  static func inactive(for targetWindowID: WindowID?) -> Self {
    Self(
      targetWindowID: targetWindowID,
      activeWindowIsFrontmost: false,
      upperBoundWindowID: nil,
      upperBoundLevel: nil
    )
  }
}

private let minimumBorderOccludingWindowArea = 2_048.0

func windowBorderStacking(
  targetWindowID: WindowID?,
  ownProcessID: pid_t,
  floatingLevel: Int,
  entries: [WindowStackEntry],
  monitorFrames: [Rect] = [],
  knownWindowIDs: Set<WindowID> = []
) -> WindowBorderStacking {
  let externalEntries = entries.filter { $0.processID != ownProcessID }
  let targetMonitorFrames: [Rect]
  if let targetWindowID,
    let targetFrame = externalEntries.first(where: {
      $0.windowID == targetWindowID
    })?.frame
  {
    targetMonitorFrames = monitorFrames.filter {
      framesIntersect($0, targetFrame)
    }
  } else {
    targetMonitorFrames = monitorFrames
  }
  let relevantEntries = externalEntries.filter { entry in
    targetMonitorFrames.isEmpty
      || targetMonitorFrames.contains { framesIntersect($0, entry.frame) }
  }
  let targetProcessID = relevantEntries.first(where: {
    $0.windowID == targetWindowID
  })?.processID
  // Untracked same-process helpers can appear during mouse-down. Known windows remain
  // occluders so a selected window's border cannot cover its app's dialogs.
  let frontmostNormalWindowID = relevantEntries.first { entry in
    entry.layer == NSWindow.Level.normal.rawValue
      && entry.frame.width * entry.frame.height >= minimumBorderOccludingWindowArea
      && (entry.windowID == targetWindowID
        || entry.processID != targetProcessID
        || knownWindowIDs.contains(entry.windowID))
  }?.windowID
  guard let targetWindowID,
    frontmostNormalWindowID == targetWindowID,
    let targetIndex = relevantEntries.firstIndex(where: {
      $0.windowID == targetWindowID
    })
  else {
    return .inactive(for: targetWindowID)
  }
  let upperBound = relevantEntries[..<targetIndex].last { entry in
    entry.layer > NSWindow.Level.normal.rawValue
      && entry.layer <= floatingLevel
  }
  return WindowBorderStacking(
    targetWindowID: targetWindowID,
    activeWindowIsFrontmost: true,
    upperBoundWindowID: upperBound?.windowID,
    upperBoundLevel: upperBound?.layer
  )
}

private func framesIntersect(_ lhs: Rect, _ rhs: Rect) -> Bool {
  lhs.x + lhs.width > rhs.x
    && lhs.x < rhs.x + rhs.width
    && lhs.y + lhs.height > rhs.y
    && lhs.y < rhs.y + rhs.height
}
