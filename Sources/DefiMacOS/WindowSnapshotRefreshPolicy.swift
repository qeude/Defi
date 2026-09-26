import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

func applicationInventoryRefreshIsRequired(
  hasCompletedSnapshot: Bool,
  topologyRequiresFullSnapshot: Bool,
  forced: Bool
) -> Bool {
  !hasCompletedSnapshot || topologyRequiresFullSnapshot || forced
}

func missingApplicationProcessIDs(
  cgWindows: [CGWindowRecord],
  knownProcessIDs: Set<pid_t>
) -> [pid_t] {
  Set(cgWindows.lazy.filter { $0.layer == 0 && $0.processID > 0 }.map(\.processID))
    .subtracting(knownProcessIDs)
    .sorted()
}

func appBundleIdentifier(executablePath: String) -> String? {
  let executable = URL(fileURLWithPath: executablePath)
    .resolvingSymlinksInPath().standardizedFileURL
  let appURL = executable.deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  guard appURL.pathExtension == "app",
    executable.deletingLastPathComponent().path
      == appURL.appending(path: "Contents/MacOS").path,
    let bundle = Bundle(url: appURL),
    bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
    bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
    bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true
  else { return nil }
  return bundle.bundleIdentifier
}

func appBundleIdentifier(processID: pid_t) -> String? {
  var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
  guard proc_pidpath(processID, &path, UInt32(path.count)) > 0 else { return nil }
  return appBundleIdentifier(executablePath: String(cString: path))
}

func resolvedFrontmostProcessID(
  appKitProcessID: pid_t?,
  appKitBundleID: String?,
  expectedBundleID: String? = nil,
  accessibilityProcessID: pid_t?,
  accessibilityBundleID: String?,
  coreGraphicsProcessID: pid_t? = nil,
  coreGraphicsBundleID: String? = nil
) -> pid_t? {
  if let appKitProcessID, appKitProcessID > 0,
    expectedBundleID == nil || appKitBundleID == expectedBundleID
  { return appKitProcessID }
  guard let bundleID = expectedBundleID ?? appKitBundleID else {
    guard let accessibilityProcessID, accessibilityProcessID > 0,
      coreGraphicsProcessID == nil
        || coreGraphicsProcessID == accessibilityProcessID
    else { return nil }
    return accessibilityProcessID
  }
  if let coreGraphicsProcessID, coreGraphicsProcessID > 0,
    bundleID == coreGraphicsBundleID
  { return coreGraphicsProcessID }
  if let accessibilityProcessID, accessibilityProcessID > 0,
    bundleID == accessibilityBundleID
  { return accessibilityProcessID }
  return nil
}

func currentFrontmostProcessID(
  appKitProcessID: pid_t? = nil,
  appKitBundleID: String? = nil,
  cgWindows: [CGWindowRecord]? = nil,
  matchingBundleID: String? = nil
) -> pid_t? {
  if let appKitProcessID, appKitProcessID > 0,
    matchingBundleID == nil || appKitBundleID == matchingBundleID
  { return appKitProcessID }
  let coreGraphicsProcessID: pid_t?
  if let cgWindows {
    coreGraphicsProcessID = cgWindows.first {
      $0.isOnscreen && $0.layer == 0 && $0.processID > 0
    }?.processID
  } else {
    let visibleWindows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    let frontmostWindow = visibleWindows.first {
      ($0[kCGWindowLayer as String] as? Int) == 0
        && ($0[kCGWindowOwnerPID as String] as? pid_t ?? 0) > 0
    }
    coreGraphicsProcessID = frontmostWindow?[kCGWindowOwnerPID as String] as? pid_t
  }
  let coreGraphicsBundleID = coreGraphicsProcessID.flatMap(appBundleIdentifier(processID:))
  if let resolved = resolvedFrontmostProcessID(
    appKitProcessID: appKitProcessID,
    appKitBundleID: appKitBundleID,
    expectedBundleID: matchingBundleID,
    accessibilityProcessID: nil,
    accessibilityBundleID: nil,
    coreGraphicsProcessID: coreGraphicsProcessID,
    coreGraphicsBundleID: coreGraphicsBundleID
  ) { return resolved }
  let system = AXUIElementCreateSystemWide()
  let focusedApplication: CFTypeRef? = AXMessagingTimeoutAccess.shared.withTimeout(
    focusSnapshotAccessibilityTimeoutSeconds,
    elements: [system]
  ) {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      system, kAXFocusedApplicationAttribute as CFString, &value
    ) == .success else { return nil }
    return value
  }
  guard let focusedApplication else { return nil }
  let focusedElement = focusedApplication as! AXUIElement
  var accessibilityProcessID: pid_t = 0
  let readProcessID = AXMessagingTimeoutAccess.shared.withTimeout(
    focusSnapshotAccessibilityTimeoutSeconds,
    elements: [focusedElement]
  ) {
    AXUIElementGetPid(focusedElement, &accessibilityProcessID) == .success
  }
  return resolvedFrontmostProcessID(
    appKitProcessID: appKitProcessID,
    appKitBundleID: appKitBundleID,
    expectedBundleID: matchingBundleID,
    accessibilityProcessID: readProcessID ? accessibilityProcessID : nil,
    accessibilityBundleID: readProcessID
      ? appBundleIdentifier(processID: accessibilityProcessID) : nil,
    coreGraphicsProcessID: coreGraphicsProcessID,
    coreGraphicsBundleID: coreGraphicsBundleID
  )
}

func durationPercentile(
  _ percentile: Double,
  sortedSamples sorted: [Double]
) -> Double {
  guard !sorted.isEmpty else { return 0 }
  let boundedPercentile = min(max(percentile, 0), 1)
  let index = Int(
    (Double(sorted.count - 1) * boundedPercentile).rounded(.up)
  )
  return sorted[index]
}

func recordDurationSample(
  _ durationMS: Double,
  in samples: inout [Double],
  limit: Int = 120
) {
  samples.append(durationMS)
  if samples.count > limit {
    samples.removeFirst(samples.count - limit)
  }
}

func applicationWindowListRefreshIsRequired(
  hasCachedWindows: Bool,
  refreshesAllWindowLists: Bool,
  topologyProcessWasInvalidated: Bool
) -> Bool {
  !hasCachedWindows
    || refreshesAllWindowLists
    || topologyProcessWasInvalidated
}

func unmatchedWindowCacheRequiresFullRetry(
  eventRequiresFullSnapshot: Bool,
  forceFullWindowRefresh: Bool,
  forceWindowListRefresh: Bool
) -> Bool {
  eventRequiresFullSnapshot
    || forceFullWindowRefresh
    || forceWindowListRefresh
}

func freshWindowObservationIDs(
  windows: [Window],
  retainedWindowIDs: Set<WindowID>,
  cachedWindowIDs: Set<WindowID> = []
) -> Set<WindowID> {
  Set(windows.lazy.map(\.id))
    .subtracting(retainedWindowIDs)
    .subtracting(cachedWindowIDs)
}

func retainedWindowIDsForCachedWindows(
  _ windows: [Window],
  previousRetainedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  previousRetainedWindowIDs.intersection(windows.lazy.map(\.id))
}

func retainedWindowRefreshProcessIDs(
  retainedWindowIDs: Set<WindowID>,
  processIDs: [WindowID: pid_t]
) -> Set<pid_t> {
  Set(retainedWindowIDs.compactMap { processIDs[$0] })
}

func windowHasExternalFrameChange(
  _ windowID: WindowID,
  pendingFrameWindowIDs: Set<WindowID>,
  matchesRecentInternalWrite: Bool = false
) -> Bool {
  pendingFrameWindowIDs.contains(windowID) && !matchesRecentInternalWrite
}

func windowIsMouseResizeGestureCandidate(
  _ windowID: WindowID,
  mouseGestureWindowID: WindowID?,
  mouseResizeGestureObserved: Bool
) -> Bool {
  mouseResizeGestureObserved
    && mouseGestureWindowID == windowID
}

func retainedFrameEventWindowIDs(
  observedFrameEventWindowIDs: Set<WindowID>,
  retainedWindowIDs: Set<WindowID>
) -> Set<WindowID> {
  observedFrameEventWindowIDs.intersection(retainedWindowIDs)
}
