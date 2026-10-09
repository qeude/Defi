import ApplicationServices
import DefiModel

struct DiscoveryMeasurementAccess: Sendable {
  var snapshotCGWindows: (@Sendable () -> [CGWindowRecord]?)? = nil
  var nativeFocus: (@Sendable ([Window]) -> WindowID?)? = nil
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

  func readDiscoveryParent(_ element: AXUIElement) -> AXUIElement? {
    if let access = discoveryMeasurementAccess { return access.relationships(element).parent }
    guard let parent = copyAttribute(element, name: kAXParentAttribute),
      CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
    return (parent as! AXUIElement)
  }

}
