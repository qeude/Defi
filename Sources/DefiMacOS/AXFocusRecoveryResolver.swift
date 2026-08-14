import ApplicationServices
import Darwin
import DefiModel
import Foundation

func focusRecoveryResolutionIsCurrent(
  requestGeneration: UInt64,
  currentGeneration: UInt64
) -> Bool {
  requestGeneration == currentGeneration
}

struct AXFocusRecoveryResolution: @unchecked Sendable {
  let element: AXUIElement
  let application: AXUIElement
}

private struct AXFocusRecoveryLookup: Sendable {
  let windowID: WindowID
  let processID: pid_t
}

final class AXFocusRecoveryResolver: @unchecked Sendable {
  private let queue = DispatchQueue(
    label: "com.quentin.defi.ax-focus-recovery",
    qos: .userInitiated
  )
  private let lock = NSLock()
  private var generation: UInt64 = 0

  func resolve(
    windowID: WindowID,
    processID: pid_t,
    completion: @escaping @Sendable (AXFocusRecoveryResolution?) -> Void
  ) {
    let lookup = AXFocusRecoveryLookup(
      windowID: windowID,
      processID: processID
    )
    lock.lock()
    generation &+= 1
    let requestGeneration = generation
    lock.unlock()
    queue.async { [weak self] in
      guard let self else { return }
      let resolution = self.resolveElement(
        windowID: lookup.windowID,
        processID: lookup.processID
      )
      guard self.isCurrent(requestGeneration) else { return }
      completion(resolution)
    }
  }

  func invalidate() {
    lock.lock()
    generation &+= 1
    lock.unlock()
  }

  private func isCurrent(_ requestGeneration: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return focusRecoveryResolutionIsCurrent(
      requestGeneration: requestGeneration,
      currentGeneration: generation
    )
  }

  private func resolveElement(
    windowID: WindowID,
    processID: pid_t
  ) -> AXFocusRecoveryResolution? {
    guard let targetCGWindowID = CGWindowID(exactly: windowID.rawValue),
      let target = copyCGWindows().first(where: {
        $0.id == targetCGWindowID && $0.processID == processID
      })
    else {
      return nil
    }
    let application = AXUIElementCreateApplication(processID)
    guard let windows = AXMessagingTimeoutAccess.shared.withTimeout(
      0.025,
      elements: [application],
      perform: {
        copyElements(
          application,
          attribute: kAXWindowsAttribute
        )
      }
    ) else {
      return nil
    }
    let candidates = windows.compactMap { element in
      boundedWindowDescription(element).map {
        (element, $0.frame, $0.title)
      }
    }
    guard let index = closestFocusRecoveryWindowIndex(
      target: (target.frame, target.title),
      candidates: candidates.map { ($0.1, $0.2) }
    ) else {
      return nil
    }
    return AXFocusRecoveryResolution(
      element: candidates[index].0,
      application: application
    )
  }

  private func boundedWindowDescription(
    _ element: AXUIElement
  ) -> (frame: Rect, title: String)? {
    AXMessagingTimeoutAccess.shared.withTimeout(
      0.01,
      elements: [element]
    ) {
      guard let positionValue = copyAttribute(element, name: kAXPositionAttribute),
        let sizeValue = copyAttribute(element, name: kAXSizeAttribute),
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
      let title = copyAttribute(element, name: kAXTitleAttribute) as? String ?? ""
      return (
        Rect(
          x: position.x,
          y: position.y,
          width: size.width,
          height: size.height
        ),
        title
      )
    }
  }

  private func copyElements(
    _ element: AXUIElement,
    attribute: String
  ) -> [AXUIElement]? {
    copyAttribute(element, name: attribute) as? [AXUIElement]
  }

  private func copyAttribute(
    _ element: AXUIElement,
    name: String
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      name as CFString,
      &value
    ) == .success else {
      return nil
    }
    return value
  }
}
