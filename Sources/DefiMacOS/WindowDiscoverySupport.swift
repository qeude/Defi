import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog

enum WindowGeometryDiscovery: Equatable {
  case unavailable
  case ignored
  case usable(Rect)
}

enum WindowDiscoveryResult {
  case unavailable
  case ignored
  case transientGeometry
  case unmatched
  case discovered(Window, CGWindowID, RuleDecision)
}

func windowDiscoveryCandidateComesFirst(
  lhsPreviousWindowID: WindowID?,
  lhsIndex: Int,
  rhsPreviousWindowID: WindowID?,
  rhsIndex: Int
) -> Bool {
  if (lhsPreviousWindowID != nil) != (rhsPreviousWindowID != nil) {
    return lhsPreviousWindowID != nil
  }
  return lhsIndex < rhsIndex
}

struct NativeWindowTabGroup: Equatable, Sendable {
  let tabTitles: [String]
  let selectedTabTitle: String?
  var backingWindowIDs: Set<WindowID>

  init(
    tabTitles: [String],
    selectedTabTitle: String? = nil,
    backingWindowIDs: Set<WindowID> = []
  ) {
    self.tabTitles = tabTitles
    self.selectedTabTitle = selectedTabTitle
    self.backingWindowIDs = backingWindowIDs
  }
}

func nativeTabGroupFrameIsInWindowChrome(
  _ tabGroupFrame: Rect,
  windowFrame: Rect
) -> Bool {
  let tabGroupRight = tabGroupFrame.x + tabGroupFrame.width
  let windowRight = windowFrame.x + windowFrame.width
  return tabGroupFrame.width > 0
    && tabGroupFrame.height > 0
    && tabGroupFrame.height <= 80
    && tabGroupFrame.width >= windowFrame.width * 0.5
    && tabGroupFrame.x >= windowFrame.x - 4
    && tabGroupRight <= windowRight + 4
    && (
      abs(tabGroupFrame.x - windowFrame.x) <= 4
        || abs(tabGroupRight - windowRight) <= 4
    )
    && tabGroupFrame.y >= windowFrame.y - 2
    && tabGroupFrame.y + tabGroupFrame.height <= windowFrame.y + 96
}

func nativeWindowTabGroupRebindingKnownMembers(
  _ detectedGroup: NativeWindowTabGroup,
  representativeID: WindowID,
  processID: pid_t,
  previousGroupsByRepresentativeID: [WindowID: NativeWindowTabGroup],
  previousProcessIDs: [WindowID: pid_t]
) -> NativeWindowTabGroup {
  if let previousGroup = previousGroupsByRepresentativeID[representativeID],
    previousGroup.tabTitles.count <= detectedGroup.tabTitles.count
  {
    var rebound = detectedGroup
    rebound.backingWindowIDs = previousGroup.backingWindowIDs
    return rebound
  }

  let replacements = previousGroupsByRepresentativeID.filter {
    previousRepresentativeID, previousGroup in
    previousProcessIDs[previousRepresentativeID] == processID
      && previousGroup.tabTitles.count == detectedGroup.tabTitles.count
      && previousGroup.backingWindowIDs.contains(representativeID)
  }
  guard replacements.count == 1,
    let replacement = replacements.first
  else { return detectedGroup }

  var reboundBackingWindowIDs = replacement.value.backingWindowIDs
  reboundBackingWindowIDs.insert(replacement.key)
  reboundBackingWindowIDs.remove(representativeID)
  guard reboundBackingWindowIDs.count == detectedGroup.tabTitles.count
    || reboundBackingWindowIDs.count + 1 == detectedGroup.tabTitles.count
  else {
    return detectedGroup
  }
  var rebound = detectedGroup
  rebound.backingWindowIDs = reboundBackingWindowIDs
  return rebound
}

func nativeWindowTabRepresentativeReplacements(
  previousWindowIDs: Set<WindowID>,
  nextWindowIDs: Set<WindowID>,
  groupsByRepresentativeID: [WindowID: NativeWindowTabGroup]
) -> [WindowID: WindowID] {
  let removedWindowIDs = previousWindowIDs.subtracting(nextWindowIDs)
  let candidates = nextWindowIDs.subtracting(previousWindowIDs).compactMap {
    representativeID -> (WindowID, WindowID)? in
    guard let group = groupsByRepresentativeID[representativeID] else {
      return nil
    }
    let previousRepresentatives = group.backingWindowIDs.intersection(
      removedWindowIDs
    )
    guard previousRepresentatives.count == 1,
      let previousRepresentativeID = previousRepresentatives.first
    else { return nil }
    return (previousRepresentativeID, representativeID)
  }
  let candidateCounts = Dictionary(grouping: candidates, by: \.0).mapValues(\.count)
  return Dictionary(
    uniqueKeysWithValues: candidates.filter { candidateCounts[$0.0] == 1 }
  )
}

func nativeTabBackingWindowIDsByRepresentative(
  windows: [Window],
  groupsByRepresentativeID: [WindowID: NativeWindowTabGroup],
  retainedWindowIDs: Set<WindowID> = [],
  additionalBackingWindowIDsByRepresentative: [WindowID: Set<WindowID>] = [:],
  maximumFrameDistance: Double = 8
) -> [WindowID: Set<WindowID>] {
  let representatives = Set(groupsByRepresentativeID.keys)
  let windowsByID = Dictionary(windows.map { ($0.id, $0) }) { current, _ in current }
  let uniqueWindows = Array(windowsByID.values)
  var backingWindowIDsByRepresentative: [WindowID: Set<WindowID>] = [:]
  var claimedWindowIDs = Set<WindowID>()

  for representativeID in representatives.sorted(by: { $0.rawValue < $1.rawValue }) {
    guard let representative = windowsByID[representativeID],
      let processID = representative.processID,
      let group = groupsByRepresentativeID[representativeID],
      group.tabTitles.isEmpty == false
    else { continue }

    var directTabTitles = group.tabTitles
    if let selectedTabTitle = group.selectedTabTitle,
      let selectedIndex = directTabTitles.firstIndex(of: selectedTabTitle)
    {
      directTabTitles.remove(at: selectedIndex)
    } else {
      directTabTitles = []
    }
    var interpretations: [(titles: [String], requiresRetention: Bool)] = []
    if group.backingWindowIDs.count <= group.tabTitles.count
    {
      interpretations.append((group.tabTitles, false))
    }
    if directTabTitles.isEmpty == false,
      group.backingWindowIDs.count <= directTabTitles.count
    {
      interpretations.append((directTabTitles, true))
    }

    func matchingBackingWindowIDs(
      titles: [String],
      requiresRetention: Bool
    ) -> Set<WindowID>? {
      var remainingTitles = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
      let knownBackingWindows = group.backingWindowIDs.compactMap { windowsByID[$0] }
        .filter { window in
          representatives.contains(window.id) == false
            && claimedWindowIDs.contains(window.id) == false
            && window.processID == processID
            && window.role == representative.role
            && window.subrole == representative.subrole
        }
      guard knownBackingWindows.count <= titles.count else { return nil }
      var backingWindowIDs = Set(knownBackingWindows.map(\.id))
      for window in knownBackingWindows {
        guard let count = remainingTitles[window.title], count > 0 else {
          return nil
        }
        remainingTitles[window.title] = count - 1
      }
      remainingTitles = remainingTitles.filter { $0.value > 0 }

      let eligibleCandidates = uniqueWindows.filter { window in
        window.id != representativeID
          && representatives.contains(window.id) == false
          && claimedWindowIDs.contains(window.id) == false
          && backingWindowIDs.contains(window.id) == false
          && window.processID == processID
          && window.role == representative.role
          && window.subrole == representative.subrole
          && remainingTitles[window.title] != nil
          && (
            !requiresRetention
              || retainedWindowIDs.contains(window.id)
              || additionalBackingWindowIDsByRepresentative[representativeID]?
                .contains(window.id) == true
          )
      }
      let nearbyCandidates = eligibleCandidates.filter {
        frameDistance($0.frame, representative.frame) <= maximumFrameDistance
      }
      let nearbyTitles = Dictionary(grouping: nearbyCandidates, by: \.title)
        .mapValues(\.count)
      let eligibleTitles = Dictionary(grouping: eligibleCandidates, by: \.title)
        .mapValues(\.count)
      let candidates: [Window]
      if nearbyTitles == remainingTitles {
        candidates = nearbyCandidates
      } else if eligibleTitles == remainingTitles {
        candidates = eligibleCandidates
      } else {
        return nil
      }
      backingWindowIDs.formUnion(candidates.lazy.map(\.id))
      return backingWindowIDs.count == titles.count ? backingWindowIDs : nil
    }

    let matches = interpretations.compactMap {
      matchingBackingWindowIDs(
        titles: $0.titles,
        requiresRetention: $0.requiresRetention
      )
    }
    guard let backingWindowIDs = matches.first,
      matches.dropFirst().allSatisfy({ $0 == backingWindowIDs })
    else { continue }
    backingWindowIDsByRepresentative[representativeID] = backingWindowIDs
    claimedWindowIDs.formUnion(backingWindowIDs)
  }

  return backingWindowIDsByRepresentative
}

struct AXWindowAttributes: Sendable {
  let minimized: Bool?
  let frame: Rect?
  let title: String
  let role: String?
  let subrole: String?
  let modal: Bool?

  init(
    minimized: Bool?,
    frame: Rect?,
    title: String,
    role: String?,
    subrole: String?,
    modal: Bool? = nil
  ) {
    self.minimized = minimized
    self.frame = frame
    self.title = title
    self.role = role
    self.subrole = subrole
    self.modal = modal
  }
}

struct PreparedAXWindowElement: @unchecked Sendable {
  let windowID: WindowID
  let processID: pid_t
  let element: AXUIElement
  let usesBatchedAttributeReads: Bool
}

struct PreparedAXApplicationElement: @unchecked Sendable {
  let processID: pid_t
  let element: AXUIElement
}

struct PreparedAXApplicationWindows: @unchecked Sendable {
  let elements: [AXUIElement]
  let durationMS: Double
}

struct PreparedAXWindowRead {
  let windowID: WindowID
  let attributes: AXWindowAttributes?
  let parent: AXUIElement?
  let sheets: [AXUIElement]
}

@MainActor
final class AXWindowIDProvider {
  private typealias GetWindowFunc =
    @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  nonisolated(unsafe) private let libraryHandle: UnsafeMutableRawPointer?
  private let getWindow: GetWindowFunc?
  private var disabled = false
  private var probeCompleted = false
  private var probeSucceeded = false
  private var probeAttempts = 0
  private var probePanel: NSPanel?
  private var probeScheduled = false

  init() {
    let handle = dlopen(
      "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle
    getWindow = handle.flatMap { handle in
      dlsym(handle, "_AXUIElementGetWindow").map {
        unsafeBitCast($0, to: GetWindowFunc.self)
      }
    }
  }

  nonisolated deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  var isAvailable: Bool {
    ensureProbe()
    return getWindow != nil && probeSucceeded && !disabled
  }

  var probeResult: Bool? {
    guard probeCompleted else { return nil }
    return getWindow != nil && probeSucceeded && !disabled
  }

  func windowID(for element: AXUIElement) -> CGWindowID? {
    ensureProbe()
    guard !disabled, probeSucceeded, let getWindow else { return nil }
    var windowID: CGWindowID = 0
    guard getWindow(element, &windowID) == .success, windowID != 0 else {
      disabled = true
      return nil
    }
    return windowID
  }

  private func ensureProbe() {
    guard !probeCompleted else { return }
    guard getWindow != nil else {
      probeCompleted = true
      return
    }
    guard NSApp != nil else { return }
    if probePanel == nil {
      let panel = NSPanel(
        contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
        styleMask: [.nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.title = "Defi AX probe \(UUID().uuidString)"
      panel.titleVisibility = .visible
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.alphaValue = 0
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.sharingType = .none
      panel.isExcludedFromWindowsMenu = true
      panel.orderFrontRegardless()
      probePanel = panel
    }
    guard !probeScheduled else { return }
    probeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      self?.runProbe()
    }
  }

  private func runProbe() {
    probeScheduled = false
    guard !probeCompleted, let getWindow, let panel = probePanel else { return }
    probeAttempts += 1

    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier),
      kAXWindowsAttribute as CFString,
      &value
      ) == .success,
      let windows = value as? [AXUIElement]
    else {
      finishInconclusiveProbe(panel)
      return
    }
    for window in windows {
      var windowTitle: CFTypeRef?
      guard AXUIElementCopyAttributeValue(
        window,
        kAXTitleAttribute as CFString,
        &windowTitle
      ) == .success,
        windowTitle as? String == panel.title
      else {
        continue
      }
      probeCompleted = true
      var windowID: CGWindowID = 0
      if getWindow(window, &windowID) == .success, windowID != 0 {
        probeSucceeded = true
      } else {
        disabled = true
      }
      panel.close()
      probePanel = nil
      return
    }
    finishInconclusiveProbe(panel)
  }

  private func finishInconclusiveProbe(_ panel: NSPanel) {
    if probeAttempts == 3 {
      probeCompleted = true
      panel.close()
      probePanel = nil
    } else {
      ensureProbe()
    }
  }
}

func preparedAXWindowAttributesAreCurrent(
  capturedGeneration: UInt64,
  currentGeneration: UInt64,
  capturedInputTimestamp: TimeInterval,
  currentInputTimestamp: TimeInterval,
  capturedWindowIDs: Set<WindowID>,
  currentWindowIDs: Set<WindowID>,
  capturedProcessIDs: Set<pid_t>,
  currentProcessIDs: Set<pid_t>
) -> Bool {
  capturedGeneration == currentGeneration
    && capturedInputTimestamp == currentInputTimestamp
    && capturedWindowIDs == currentWindowIDs
    && capturedProcessIDs == currentProcessIDs
}

func transientOwnerWindowIDsFromPreparedRelationships(
  elements: [WindowID: AXUIElement],
  parents: [WindowID: AXUIElement],
  sheets: [WindowID: [AXUIElement]]
) -> [WindowID: WindowID] {
  var ownerWindowIDs: [WindowID: WindowID] = [:]
  // ponytail: window counts are small; index AX identities if this background scan matters.
  for (childID, parent) in parents {
    ownerWindowIDs[childID] = elements.first {
      $0.key != childID && CFEqual($0.value, parent)
    }?.key
  }
  for (ownerID, ownerSheets) in sheets {
    for sheet in ownerSheets {
      guard let childID = elements.first(where: {
        $0.key != ownerID && CFEqual($0.value, sheet)
      })?.key else { continue }
      ownerWindowIDs[childID] = ownerWindowIDs[childID] ?? ownerID
    }
  }
  return ownerWindowIDs
}

private func axElementValue(_ value: CFTypeRef?) -> AXUIElement? {
  guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return (value as! AXUIElement)
}

func copyBatchedWindowAttributes(
  _ element: AXUIElement,
  includingTransientRelationships: Bool = false
) -> (
  error: AXError,
  attributes: AXWindowAttributes?,
  parent: AXUIElement?,
  sheets: [AXUIElement]?
) {
  var names = [
    kAXMinimizedAttribute,
    kAXPositionAttribute,
    kAXSizeAttribute,
    kAXTitleAttribute,
    kAXRoleAttribute,
    kAXSubroleAttribute,
    kAXModalAttribute,
  ]
  if includingTransientRelationships {
    names += [kAXParentAttribute, "AXSheets"]
  }
  var copiedValues: CFArray?
  let error = AXUIElementCopyMultipleAttributeValues(
    element,
    names as CFArray,
    AXCopyMultipleAttributeOptions(rawValue: 0),
    &copiedValues
  )
  guard error == .success,
    let values = copiedValues as? [AnyObject],
    values.count == names.count
  else {
    return (error, nil, nil, nil)
  }
  let parent = values.count > 7 ? axElementValue(axAttributeValue(values[7])) : nil
  return (
    error,
    AXWindowAttributes(
      minimized: axAttributeValue(values[0]) as? Bool,
      frame: frameFromAXValues(
        positionValue: axAttributeValue(values[1]),
        sizeValue: axAttributeValue(values[2])
      ),
      title: axAttributeValue(values[3]) as? String ?? "",
      role: axAttributeValue(values[4]) as? String,
      subrole: axAttributeValue(values[5]) as? String,
      modal: axAttributeValue(values[6]) as? Bool
    ),
    parent,
    values.count > 8 ? axAttributeValue(values[8]) as? [AXUIElement] : nil
  )
}

func copyTransientOwnerRelationships(
  _ element: AXUIElement
) -> (parent: AXUIElement?, sheets: [AXUIElement]) {
  var parentValue: CFTypeRef?
  _ = AXUIElementCopyAttributeValue(
    element,
    kAXParentAttribute as CFString,
    &parentValue
  )
  let parent = axElementValue(parentValue)
  var sheetsValue: CFTypeRef?
  let sheets = AXUIElementCopyAttributeValue(
    element,
    "AXSheets" as CFString,
    &sheetsValue
  ) == .success
    ? sheetsValue as? [AXUIElement] ?? []
    : []
  return (parent, sheets)
}

private func frameFromAXValues(
  positionValue: CFTypeRef?,
  sizeValue: CFTypeRef?
) -> Rect? {
  guard let positionValue,
    let sizeValue,
    CFGetTypeID(positionValue) == AXValueGetTypeID(),
    CFGetTypeID(sizeValue) == AXValueGetTypeID()
  else {
    return nil
  }
  var position = CGPoint.zero
  var size = CGSize.zero
  guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
  else {
    return nil
  }
  return Rect(
    x: position.x,
    y: position.y,
    width: size.width,
    height: size.height
  )
}

struct WindowManagementCapabilities: Equatable {
  let hasCloseButton: Bool
  let canResize: Bool
  let isModal: Bool
}

func shouldDisableBatchedWindowAttributeReads(failureCount: Int) -> Bool {
  failureCount >= 3
}

func fallbackWindowAttributes(
  minimized: () -> Bool?,
  frame: () -> Rect?,
  title: () -> String?,
  role: () -> String?,
  subrole: () -> String?,
  modal: () -> Bool?
) -> AXWindowAttributes {
  let minimizedValue = minimized()
  guard minimizedValue != true else {
    return AXWindowAttributes(
      minimized: true,
      frame: nil,
      title: "",
      role: nil,
      subrole: nil
    )
  }
  return AXWindowAttributes(
    minimized: minimizedValue,
    frame: frame(),
    title: title() ?? "",
    role: role(),
    subrole: subrole(),
    modal: modal()
  )
}

func axAttributeValue(_ value: AnyObject) -> CFTypeRef? {
  let rawValue = value as CFTypeRef
  guard rawValue !== kCFNull else { return nil }
  if CFGetTypeID(rawValue) == AXValueGetTypeID(),
    AXValueGetType(rawValue as! AXValue) == .axError
  {
    return nil
  }
  return rawValue
}

func windowGeometryDiscovery(
  minimized: Bool?,
  frame: () -> Rect?
) -> WindowGeometryDiscovery {
  if minimized == true {
    return .ignored
  }
  guard let frame = frame() else {
    return .unavailable
  }
  guard frame.width >= 80, frame.height >= 60 else {
    return .ignored
  }
  return .usable(frame)
}

func cachedWindowIDsToRetain(
  processID: pid_t,
  previousWindows: [Window],
  discoveredWindowIDs: Set<WindowID>,
  ignoredWindowIDs: Set<WindowID>,
  cgWindows: [CGWindowRecord]?,
  cachedMinimizedState: ((WindowID) -> Bool?)?
) -> Set<WindowID> {
  var retainedWindowIDs = Set(previousWindows.map(\.id))
    .subtracting(discoveredWindowIDs)
    .subtracting(ignoredWindowIDs)
  if let cgWindows {
    let liveWindowIDs = Set(
      cgWindows.lazy
        .filter { $0.processID == processID }
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    retainedWindowIDs.formIntersection(liveWindowIDs)
  }
  guard let cachedMinimizedState else { return retainedWindowIDs }
  return Set(retainedWindowIDs.filter { cachedMinimizedState($0) != true })
}

func retainedWindowIDsWithinGracePeriod(
  _ candidates: Set<WindowID>,
  previousDeadlines: [WindowID: TimeInterval],
  now: TimeInterval,
  gracePeriod: TimeInterval = 0.75
) -> (windowIDs: Set<WindowID>, deadlines: [WindowID: TimeInterval]) {
  var retained = Set<WindowID>()
  var deadlines: [WindowID: TimeInterval] = [:]
  for windowID in candidates {
    let deadline = previousDeadlines[windowID] ?? now + gracePeriod
    guard now < deadline else { continue }
    retained.insert(windowID)
    deadlines[windowID] = deadline
  }
  return (retained, deadlines)
}

func consistentFocusedProcessID(
  accessibilityProcessID: pid_t?,
  frontmostProcessID: pid_t?,
  verifiedNativeFocusProcessID: pid_t? = nil
) -> pid_t? {
  if let accessibilityProcessID,
    let frontmostProcessID,
    accessibilityProcessID != frontmostProcessID
  {
    return verifiedNativeFocusProcessID == frontmostProcessID
      ? frontmostProcessID
      : nil
  }
  return accessibilityProcessID ?? frontmostProcessID
}

func focusedWindowIDMatchingFrame(
  processID: pid_t,
  focusedFrame: Rect,
  windows: [Window],
  maximumDistance: Double = 80
) -> WindowID? {
  let ranked = windows.filter {
    $0.processID == processID
  }.sorted {
    frameDistance($0.frame, focusedFrame) < frameDistance($1.frame, focusedFrame)
  }
  guard let closest = ranked.first,
    frameDistance(closest.frame, focusedFrame) <= maximumDistance
  else {
    return nil
  }
  if ranked.count > 1,
    abs(
      frameDistance(closest.frame, focusedFrame)
        - frameDistance(ranked[1].frame, focusedFrame)
    ) < 0.5
  {
    return nil
  }
  return closest.id
}
