import ApplicationServices

final class AXFrameAccessibilityWriter {
  func applySize(
    _ write: AsyncPositionWrite,
    size: CGSize,
    enhancedUIManagedByBatch: Bool = false
  ) -> Bool {
    let initialResult = applySizeValue(write, size: size)
    if initialResult == .success {
      return true
    }
    guard initialResult != .cannotComplete,
      write.enhancedUIWasEnabled
    else {
      return false
    }
    if enhancedUIManagedByBatch {
      return applySizeValue(write, size: size) == .success
    }
    setEnhancedUserInterface(false, application: write.application)
    defer {
      setEnhancedUserInterface(true, application: write.application)
    }
    return applySizeValue(write, size: size) == .success
  }

  func applyPosition(
    _ write: AsyncPositionWrite,
    point: CGPoint,
    forceOffscreenAccess: Bool = false,
    suppressNativeAnimation: Bool = false,
    enhancedUIManagedByBatch: Bool = false
  ) -> Bool {
    if suppressNativeAnimation, write.enhancedUIWasEnabled {
      // WindowServer can animate a successful offscreen-to-visible AX write.
      if !enhancedUIManagedByBatch {
        setEnhancedUserInterface(false, application: write.application)
      }
      defer {
        if !enhancedUIManagedByBatch {
          setEnhancedUserInterface(true, application: write.application)
        }
      }
      return apply(write, point: point) == .success
    }
    if write.isParked || forceOffscreenAccess {
      if !enhancedUIManagedByBatch {
        setEnhancedUserInterface(false, application: write.application)
      }
      defer {
        if !enhancedUIManagedByBatch, write.enhancedUIWasEnabled {
          setEnhancedUserInterface(true, application: write.application)
        }
      }
      for _ in 0..<2 {
        guard apply(write, point: point) == .success else { continue }
        guard let actual = readPosition(write.element) else { return true }
        if pointDistance(actual, point) <= 1 {
          return true
        }
      }
      return false
    }
    let initialResult = apply(write, point: point)
    if initialResult == .success {
      return true
    }
    guard initialResult != .cannotComplete,
      write.enhancedUIWasEnabled
    else {
      return false
    }
    if enhancedUIManagedByBatch {
      return apply(write, point: point) == .success
    }
    setEnhancedUserInterface(false, application: write.application)
    defer {
      setEnhancedUserInterface(true, application: write.application)
    }
    return apply(write, point: point) == .success
  }

  func readPosition(_ element: AXUIElement) -> CGPoint? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXPositionAttribute as CFString,
        &rawValue
      ) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var point = CGPoint.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) else {
      return nil
    }
    return point
  }

  func readSize(_ element: AXUIElement) -> CGSize? {
    var rawValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        kAXSizeAttribute as CFString,
        &rawValue
      ) == .success,
      let rawValue,
      CFGetTypeID(rawValue) == AXValueGetTypeID()
    else {
      return nil
    }
    var size = CGSize.zero
    guard AXValueGetValue(rawValue as! AXValue, .cgSize, &size) else {
      return nil
    }
    return size
  }

  func pointDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
    abs(lhs.x - rhs.x) + abs(lhs.y - rhs.y)
  }

  private func apply(
    _ write: AsyncPositionWrite,
    point: CGPoint
  ) -> AXError {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else {
      return .failure
    }
    return AXUIElementSetAttributeValue(
      write.element,
      kAXPositionAttribute as CFString,
      value
    )
  }

  private func applySizeValue(
    _ write: AsyncPositionWrite,
    size: CGSize
  ) -> AXError {
    var size = size
    guard let value = AXValueCreate(.cgSize, &size) else { return .failure }
    return AXUIElementSetAttributeValue(
      write.element,
      kAXSizeAttribute as CFString,
      value
    )
  }

  func setEnhancedUserInterface(
    _ enabled: Bool,
    application: AXUIElement
  ) {
    AXUIElementSetAttributeValue(
      application,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse
    )
  }
}
