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
  knownProcessIDs: Set<pid_t>,
  previouslyManagedProcessIDs: Set<pid_t>
) -> [pid_t] {
  Set(cgWindows.lazy.filter {
    $0.layer == 0 && $0.processID > 0
      && ($0.isOnscreen || previouslyManagedProcessIDs.contains($0.processID))
  }.map(\.processID))
    .subtracting(knownProcessIDs)
    .sorted()
}

func fallbackApplicationIdentity(
  bundleIdentifier: String?, ownerName: String?, processID: pid_t
) -> String {
  if let bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
  if let ownerName, !ownerName.isEmpty { return ownerName }
  return "pid-\(processID)"
}

func missingApplicationFallbackIsEligible(
  isTerminated: Bool, isRegularApplication: Bool?, hasValidatedBundle: Bool
) -> Bool {
  !isTerminated && (isRegularApplication ?? hasValidatedBundle)
}

/// PID plus CG window ID identifies a surface; owner and title are diagnostic metadata.
struct CGWindowDiscoveryIdentity: Hashable, Sendable {
  let windowID: WindowID
  let processID: pid_t
  let ownerName: String
  let title: String

  init(record: CGWindowRecord) {
    self.init(
      windowID: WindowID(rawValue: UInt64(record.id)), processID: record.processID,
      ownerName: record.ownerName, title: record.title
    )
  }

  init(windowID: WindowID, processID: pid_t, ownerName: String, title: String) {
    self.windowID = windowID
    self.processID = processID
    self.ownerName = ownerName
    self.title = title
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.windowID == rhs.windowID && lhs.processID == rhs.processID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(windowID)
    hasher.combine(processID)
  }
}

struct CGWindowDiscoveryRetry: Equatable, Sendable {
  let firstObservedAt: TimeInterval
  var attempts = 0
  var nextRetryAt: TimeInterval?
  var lastOutcome: String
}

struct CGWindowDiscoveryRetryTracker: Sendable {
  // Three PID-targeted retries bound an unresolved surface to 100/200/400 ms
  // backoff; each pass retains the existing 12 ms fresh-read budget and 50 ms
  // AX timeout. Exhausted records stay diagnosable and wait for a new event or
  // the normal inventory watchdog.
  static let retryDelays: [TimeInterval] = [0.1, 0.2, 0.4]

  private(set) var entries: [CGWindowDiscoveryIdentity: CGWindowDiscoveryRetry] = [:]

  mutating func observe(
    observed: Set<CGWindowDiscoveryIdentity>,
    unresolved: [CGWindowDiscoveryIdentity: String],
    now: TimeInterval
  ) {
    entries = entries.filter { observed.contains($0.key) && unresolved[$0.key] != nil }
    for (identity, outcome) in unresolved where entries[identity] == nil {
      entries[identity] = CGWindowDiscoveryRetry(
        firstObservedAt: now, nextRetryAt: now + Self.retryDelays[0],
        lastOutcome: outcome
      )
    }
  }

  func dueProcessIDs(now: TimeInterval) -> Set<pid_t> {
    Set(entries.compactMap { identity, retry -> pid_t? in
      guard let nextRetryAt = retry.nextRetryAt, nextRetryAt <= now else {
        return nil
      }
      return identity.processID
    })
  }

  func refreshInterval(now: TimeInterval) -> TimeInterval? {
    entries.values.compactMap(\.nextRetryAt).map { max($0 - now, 0) }.min()
  }

  mutating func completeRetries(
    processIDs: Set<pid_t>, now: TimeInterval,
    unresolved: [CGWindowDiscoveryIdentity: String]
  ) {
    for identity in entries.keys where processIDs.contains(identity.processID) {
      guard var retry = entries[identity],
        let dueAt = retry.nextRetryAt, dueAt <= now,
        let outcome = unresolved[identity]
      else { continue }
      retry.attempts += 1
      retry.lastOutcome = outcome
      retry.nextRetryAt = retry.attempts < Self.retryDelays.count
        ? now + Self.retryDelays[retry.attempts] : nil
      entries[identity] = retry
    }
  }
}

struct CGWindowDiscoveryDiagnostic: Equatable, Sendable {
  let identity: CGWindowDiscoveryIdentity
  let appIdentity: String
  let classification: String
  let reason: String?
  let retry: CGWindowDiscoveryRetry?

  func detail(now: TimeInterval) -> String {
    var fields = [
      "id=\(identity.windowID.rawValue)", "pid=\(identity.processID)",
      "app=\(appIdentity)", "class=\(classification)",
    ]
    if let reason { fields.append("reason=\(reason)") }
    if classification == "unresolved", let retry {
      fields.append("age=\(String(format: "%.2f", max(now - retry.firstObservedAt, 0)))s")
      fields.append("retry=\(retry.attempts)/\(CGWindowDiscoveryRetryTracker.retryDelays.count)")
      fields.append("outcome=\(retry.lastOutcome)")
    }
    return fields.joined(separator: ",")
  }

  var traceSignature: String {
    "\(appIdentity):\(classification):\(reason ?? ""):"
      + "\(retry?.attempts ?? 0):\(retry?.lastOutcome ?? "")"
  }
}

func relevantCGWindowDiscoveryRecords(
  _ records: [CGWindowRecord], ownProcessID: pid_t,
  previouslyManagedProcessIDs: Set<pid_t>
) -> [CGWindowRecord] {
  records.filter {
    $0.layer == 0 && $0.processID > 0 && $0.processID != ownProcessID
      && ($0.isOnscreen || previouslyManagedProcessIDs.contains($0.processID))
  }
}

func uniquelyMatchedCGWindowReasons(
  records: [CGWindowRecord],
  candidatesByProcess: [pid_t: [IgnoredWindowCandidate]]
) -> [WindowID: String] {
  var reasons: [WindowID: String] = [:]
  for (processID, candidates) in candidatesByProcess {
    for candidate in candidates where !candidate.title.isEmpty {
      guard candidates.filter({ $0.title == candidate.title }).count == 1 else { continue }
      let matches = records.filter {
        $0.processID == processID && $0.layer == 0 && $0.title == candidate.title
      }
      guard matches.count == 1, let match = matches.first else { continue }
      reasons[WindowID(rawValue: UInt64(match.id))] = candidate.reason
    }
  }
  return reasons
}

func cgWindowDiscoveryClassification(
  record: CGWindowRecord,
  windows: [Window],
  processIDsByWindowID: [WindowID: pid_t],
  appIdentity: String?,
  ignoredProcessReason: String?,
  nativeFullscreenWindowIDs: Set<WindowID>,
  nativeFullscreenProcessIDs: Set<pid_t>,
  monitors: [MonitorSnapshot],
  transientWindowIDs: Set<WindowID>,
  minimizedWindowIDs: Set<WindowID>,
  ignoredReasonsByWindowID: [WindowID: String]
) -> (classification: String, reason: String?) {
  let windowID = WindowID(rawValue: UInt64(record.id))
  if (nativeFullscreenWindowIDs.contains(windowID)
      && processIDsByWindowID[windowID] == record.processID)
    || (nativeFullscreenProcessIDs.contains(record.processID)
      && monitors.contains(where: {
        fullscreenFrameMatches(record.frame, $0.physicalFrame)
      }))
  {
    return ("native-fullscreen", nil)
  }
  if processIDsByWindowID[windowID] == record.processID,
    let window = windows.first(where: { $0.id == windowID && $0.processID == record.processID })
  {
    if transientWindowIDs.contains(windowID) || window.isModal || window.role == kAXSheetRole {
      return ("transient", nil)
    }
    return (window.floating ? "floating" : "tiled", nil)
  }
  if minimizedWindowIDs.contains(windowID) { return ("minimized", nil) }
  if let reason = ignoredReasonsByWindowID[windowID] {
    return (reason == "frame-below-80x60" ? "transient" : "ignored", reason)
  }
  if let ignoredProcessReason { return ("ignored", ignoredProcessReason) }
  if isIgnoredWindowApplication(appIdentity ?? record.ownerName) {
    return ("ignored", "application-policy")
  }
  return ("unresolved", nil)
}

func formattedCGWindowDiscoveryStatus(
  _ diagnostics: [CGWindowDiscoveryDiagnostic], now: TimeInterval,
  detailLimit: Int = 8
) -> String {
  let counts = Dictionary(grouping: diagnostics, by: \.classification).mapValues(\.count)
  let categories = ["tiled", "floating", "transient", "native-fullscreen", "minimized", "ignored", "unresolved"]
  let summary = categories.map { "\($0)=\(counts[$0, default: 0])" }.joined(separator: ",")
  let details = diagnostics.prefix(detailLimit).map { $0.detail(now: now) }.joined(separator: ";")
  let omitted = max(diagnostics.count - detailLimit, 0)
  return "scope=layer0,pid>0,onscreen-or-managed ax=best-effort-not-one-to-one count=\(diagnostics.count)[\(summary)] details=[\(details)] omitted=\(omitted)"
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
