import AppKit
import Synchronization
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

func windowCandidatesIncludingCreatedElements(
  _ listed: [AXUIElement], created: [AXUIElement]
) -> [AXUIElement] {
  var candidates = listed
  for element in created where !candidates.contains(where: { CFEqual($0, element) }) {
    candidates.append(element)
  }
  return candidates
}

enum WindowDiscoveryResult {
  case unavailable
  case ignored(reason: String, title: String)
  case transientGeometry(title: String)
  case unmatched(title: String)
  case discovered(Window, CGWindowID, RuleDecision)
}

struct IgnoredWindowCandidate: Sendable {
  let title: String
  let reason: String
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

/// A native tab group is one logical window: Defi manages its visible member and remembers
/// the hidden members by WindowServer ID. Titles never decide membership; siblings often
/// share them. AppKit lists only the selected tab in Accessibility and orders the others
/// out at the group's frame. WindowServer can still report the previous order when the
/// Accessibility list already shows the new tab, so a new tab does not wait for it.
///
/// "Gone" means no longer listed, ordered out, or destroyed.
///
/// | Event              | Managed member V        | Newly listed window A      | Result                 |
/// |--------------------|-------------------------|----------------------------|------------------------|
/// | new tab            | any                     | at V's frame, AX tabs      | V -> A, hidden + V     |
/// | new tab, no AX tabs| gone                    | at V's frame               | V -> A, hidden + V     |
/// | switch tab         | gone                    | hidden H at V's frame      | V -> H, hidden + V - H |
/// | close visible tab  | destroyed               | hidden H at V's frame      | V -> H, hidden - H     |
/// | close hidden tab   | listed                  | none                       | hidden - H             |
/// | new window, Cmd-N  | listed                  | elsewhere, or without tabs | new column             |
/// | tab dragged out    | listed, moved           | H or the tab, elsewhere    | new column, released   |
///
/// A pair needs the same process, frames within `maximumFrameDistance`, and exactly one
/// candidate on each side; anything else is ordinary window handling.
struct NativeTabSurface: Equatable {
  let frame: Rect
  let isOnscreen: Bool
}

struct NativeTabTransition: Equatable {
  /// Previous visible member to the member that now represents the same logical window.
  var replacements: [WindowID: WindowID] = [:]
  var hiddenMembersByVisibleID: [WindowID: Set<WindowID>] = [:]

  var hiddenWindowIDs: Set<WindowID> { Set(hiddenMembersByVisibleID.values.joined()) }
}

/// One process's transition between two snapshots.
/// - Parameters:
///   - previousFrames: windows managed in the previous snapshot.
///   - listedFrames: windows the Accessibility list shows now, with their frames.
///   - tabbedIDs: listed windows with an `AXTabGroup` of two or more tabs.
///   - surfaces: the process's WindowServer records; a missing ID is destroyed.
func nativeTabTransition(
  previousFrames: [WindowID: Rect],
  listedFrames: [WindowID: Rect],
  tabbedIDs: Set<WindowID>,
  hiddenMembersByVisibleID: [WindowID: Set<WindowID>],
  surfaces: [WindowID: NativeTabSurface],
  maximumFrameDistance: Double = 2
) -> NativeTabTransition {
  func near(_ lhs: Rect, _ rhs: Rect) -> Bool {
    frameDistance(lhs, rhs) <= maximumFrameDistance
  }
  let arrivals = listedFrames.filter { previousFrames[$0.key] == nil }
  let pairs = previousFrames.flatMap { member, lastFrame in
    let frame = surfaces[member]?.frame ?? lastFrame
    let departed = listedFrames[member] == nil || surfaces[member]?.isOnscreen != true
    let hidden = hiddenMembersByVisibleID[member] ?? []
    return arrivals.compactMap { arrived, arrivedFrame -> (WindowID, WindowID)? in
      // Only a new tab may claim a slot whose window is still listed; a known member
      // waits for it to leave, or both would claim the slot in turn.
      near(frame, arrivedFrame)
        && (departed || (tabbedIDs.contains(arrived) && !hidden.contains(arrived)))
        ? (member, arrived) : nil
    }
  }
  let memberCounts = Dictionary(grouping: pairs, by: \.0).mapValues(\.count)
  let arrivedCounts = Dictionary(grouping: pairs, by: \.1).mapValues(\.count)
  var transition = NativeTabTransition()
  var hidden = hiddenMembersByVisibleID.filter { previousFrames[$0.key] != nil }
  for (member, arrived) in pairs
  where memberCounts[member] == 1 && arrivedCounts[arrived] == 1 {
    transition.replacements[member] = arrived
    var members = hidden.removeValue(forKey: member) ?? []
    members.insert(member)
    members.remove(arrived)
    hidden[arrived] = members
  }
  // A destroyed member is gone; one listed away from the group became an ordinary window.
  transition.hiddenMembersByVisibleID = Dictionary(uniqueKeysWithValues: hidden.compactMap {
    visible, members in
    let groupFrame = listedFrames[visible] ?? surfaces[visible]?.frame
    let kept = members.filter { member in
      guard surfaces[member] != nil else { return false }
      guard let listedFrame = listedFrames[member] else { return true }
      return groupFrame.map { near(listedFrame, $0) } ?? false
    }
    return kept.isEmpty ? nil : (visible, kept)
  })
  return transition
}

/// Until when a process with native tab groups is reread: briefly after each of its events,
/// and at most a second while its groups stay unsettled.
func nativeTabSettleDeadline(
  previous: TimeInterval?,
  hasGroups: Bool,
  observedEvent: Bool,
  settling: Bool,
  now: TimeInterval
) -> TimeInterval? {
  guard hasGroups else { return nil }
  var deadline = previous
  if settling, deadline == nil { deadline = now + 1 }
  // The idle timer wakes at most every 0.3 s; leave room for two rereads.
  if observedEvent { deadline = max(deadline ?? now, now + 0.7) }
  return settling || deadline.map { $0 > now } == true ? deadline : nil
}

/// Accessibility and WindowServer still disagree about which member of a group is visible.
func nativeTabGroupsAreSettling(
  _ hiddenMembersByVisibleID: [WindowID: Set<WindowID>],
  listedFrames: [WindowID: Rect],
  surfaces: [WindowID: NativeTabSurface]
) -> Bool {
  hiddenMembersByVisibleID.contains { visible, members in
    listedFrames[visible] == nil || surfaces[visible]?.isOnscreen != true
      || members.contains { listedFrames[$0] != nil || surfaces[$0]?.isOnscreen == true }
  }
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
  let elements: [AXUIElement]?
  let durationMS: Double
}

struct PreparedAXProcessRead: Sendable {
  let processID: pid_t
  let windows: [PreparedAXWindowElement]
  let application: PreparedAXApplicationElement?
}

struct PreparedAXProcessReadResult: @unchecked Sendable {
  let processID: pid_t
  let windows: [PreparedAXWindowRead]
  let application: PreparedAXApplicationWindows?
}

func collectPreparedAXProcessReads(
  _ jobs: [PreparedAXProcessRead],
  maximumConcurrent: Int = 4,
  shouldStart: (pid_t) -> Bool,
  read: @escaping @Sendable (PreparedAXProcessRead) -> PreparedAXProcessReadResult
) -> [PreparedAXProcessReadResult] {
  guard !jobs.isEmpty else { return [] }
  precondition(Set(jobs.map(\.processID)).count == jobs.count)
  let limit = max(1, min(maximumConcurrent, jobs.count))
  let completed = Mutex<[(Int, PreparedAXProcessReadResult)]>([])
  let completion = DispatchSemaphore(value: 0)
  var nextIndex = 0
  var active = 0
  var results: [(Int, PreparedAXProcessReadResult)] = []
  while nextIndex < jobs.count || active > 0 {
    while active < limit && nextIndex < jobs.count {
      let index = nextIndex
      nextIndex += 1
      let job = jobs[index]
      guard shouldStart(job.processID) else { continue }
      active += 1
      DispatchQueue.global(qos: .userInitiated).async {
        let result = read(job)
        completed.withLock { $0.append((index, result)) }
        completion.signal()
      }
    }
    if active > 0 {
      completion.wait()
      results.append(completed.withLock { $0.removeFirst() })
      active -= 1
    }
  }
  return results.sorted { $0.0 < $1.0 }.map(\.1)
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

func validatedWindowFrame(_ frame: Rect) -> Rect? {
  guard frame.x.isFinite, frame.y.isFinite, frame.width.isFinite, frame.height.isFinite,
    frame.width > 0, frame.height > 0
  else { return nil }
  return frame
}

func decodeWindowFrame(_ values: [AnyObject]) -> Rect? {
  guard values.count == 2,
    let frame = frameFromAXValues(
      positionValue: axAttributeValue(values[0]), sizeValue: axAttributeValue(values[1])
    )
  else { return nil }
  return validatedWindowFrame(frame)
}

func copyWindowFrame(
  _ element: AXUIElement,
  multipleReader: (AXUIElement) -> (AXError, [AnyObject]?) = { element in
    var values: CFArray?
    let error = AXUIElementCopyMultipleAttributeValues(
      element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray,
      AXCopyMultipleAttributeOptions(rawValue: 0), &values
    )
    return (error, values as? [AnyObject])
  },
  attributeReader: (AXUIElement, CFString) -> CFTypeRef? = { element, attribute in
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute, &value) == .success ? value : nil
  }
) -> Rect? {
  let (error, values) = multipleReader(element)
  if error == .success { return values.flatMap(decodeWindowFrame) }
  guard error == .attributeUnsupported || error == .notImplemented,
    let position = attributeReader(element, kAXPositionAttribute as CFString),
    let size = attributeReader(element, kAXSizeAttribute as CFString)
  else { return nil }
  return decodeWindowFrame([position, size])
}

func frameFromAXValues(
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
  unresolvedWindowIDs: Set<WindowID> = [],
  cgWindows: [CGWindowRecord]?,
  previousElements: [WindowID: AXUIElement] = [:],
  discoveredElements: [WindowID: AXUIElement] = [:],
  cachedWindowState: ((WindowID) -> (error: AXError, minimized: Bool?))?
) -> Set<WindowID> {
  var retainedWindowIDs = Set(previousWindows.map(\.id))
    .union(unresolvedWindowIDs)
    .subtracting(discoveredWindowIDs)
    .subtracting(ignoredWindowIDs)
  let liveElements = Set(discoveredElements.values)
  retainedWindowIDs = retainedWindowIDs.filter { windowID in
    // One AX element cannot own both a newly discovered ID and a cached ID.
    previousElements[windowID].map { !liveElements.contains($0) } ?? true
  }
  if let cgWindows {
    let liveWindowIDs = Set(
      cgWindows.lazy
        .filter { $0.processID == processID }
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    let foreignWindowIDs = Set(
      cgWindows.lazy
        .filter { $0.processID != processID }
        .map { WindowID(rawValue: UInt64($0.id)) }
    )
    retainedWindowIDs = retainedWindowIDs.filter {
      !foreignWindowIDs.contains($0)
        && (liveWindowIDs.contains($0) || unresolvedWindowIDs.contains($0))
    }
  }
  guard let cachedWindowState else { return retainedWindowIDs }
  return Set(retainedWindowIDs.filter {
    let state = cachedWindowState($0)
    // A stale AX connection after wake can also report invalidUIElement.
    // Require WindowServer to confirm the surface is no longer displayed.
    let windowID = $0
    let surfaceIsAbsent = cgWindows.map { windows in
      !windows.contains(where: { $0.id == windowID.rawValue && $0.isOnscreen })
    } ?? false
    let closed = state.error == .invalidUIElement && surfaceIsAbsent
    return !closed && state.minimized != true
  })
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
