import ApplicationServices
import DefiModel

struct DiscoveryMeasurementAccess: Sendable {
  var now: @Sendable () -> TimeInterval
  var applicationWindows: @Sendable (AXUIElement, pid_t) -> [AXUIElement]?
  var windowAttributes: @Sendable (AXUIElement, pid_t) -> AXWindowAttributes
  var relationships: @Sendable (AXUIElement) -> (parent: AXUIElement?, sheets: [AXUIElement])
}

extension SnapshotEngine {
  var discoveryNow: TimeInterval {
    discoveryMeasurementAccess?.now() ?? ProcessInfo.processInfo.systemUptime
  }

  func readDiscoveryApplicationWindows(_ element: AXUIElement, processID: pid_t) -> [AXUIElement]? {
    if let access = discoveryMeasurementAccess { return access.applicationWindows(element, processID) }
    return copyElements(element, attribute: kAXWindowsAttribute)
  }

  func readDiscoveryRelationships(_ element: AXUIElement) -> (parent: AXUIElement?, sheets: [AXUIElement]) {
    if let access = discoveryMeasurementAccess { return access.relationships(element) }
    return copyTransientOwnerRelationships(element)
  }

  func readPreparedDiscoveryAttributes(
    _ element: AXUIElement, processID: pid_t, relationships: Bool
  ) -> (attributes: AXWindowAttributes?, parent: AXUIElement?, sheets: [AXUIElement]?) {
    if let access = discoveryMeasurementAccess {
      let attributes = access.windowAttributes(element, processID)
      let relation = relationships ? access.relationships(element) : (parent: nil, sheets: [])
      return (attributes, relation.parent, relation.sheets)
    }
    let read = copyBatchedWindowAttributes(element, includingTransientRelationships: relationships)
    return (read.attributes, read.parent, read.sheets)
  }
}
