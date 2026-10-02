import ApplicationServices
import DefiModel

final class AXFrameAccessibilityWriter {
  private let positionWriter: ((AsyncPositionWrite, CGPoint) -> Bool)?
  private let positionReader: ((AXUIElement) -> CGPoint?)?
  private let enhancedUIWriter: ((AXUIElement, Bool) -> Bool)?

  let nativePositionReader: (WindowID, pid_t) -> CGPoint?
  let independentBorderObservationAvailable: () -> Bool

  init(
    positionWriter: ((AsyncPositionWrite, CGPoint) -> Bool)? = nil,
    positionReader: ((AXUIElement) -> CGPoint?)? = nil,
    enhancedUIWriter: ((AXUIElement, Bool) -> Bool)? = nil,
    nativePositionReader: @escaping (WindowID, pid_t) -> CGPoint? = readWindowServerPosition,
    independentBorderObservationAvailable: @escaping () -> Bool = { false }
  ) {
    self.positionWriter = positionWriter
    self.positionReader = positionReader
    self.enhancedUIWriter = enhancedUIWriter
    self.nativePositionReader = nativePositionReader
    self.independentBorderObservationAvailable = independentBorderObservationAvailable
  }

  static func readWindowServerPosition(_ windowID: WindowID, processID: pid_t) -> CGPoint? {
    guard let rawID = CGWindowID(exactly: windowID.rawValue),
      let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, rawID) as? [[String: Any]],
      let record = rows.compactMap(cgWindowRecord).first(where: {
        $0.id == rawID && $0.processID == processID && $0.layer == 0
      }), record.frame.x.isFinite, record.frame.y.isFinite,
      record.frame.width.isFinite, record.frame.height.isFinite,
      record.frame.width > 0, record.frame.height > 0
    else { return nil }
    return CGPoint(x: record.frame.x, y: record.frame.y)
  }

  func applySize(
    _ write: AsyncPositionWrite,
    size: CGSize,
    enhancedUIManagedByBatch: Bool = false,
    shouldApply: () -> Bool = { true }
  ) -> Bool {
    guard shouldApply() else { return false }
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
      return shouldApply() && applySizeValue(write, size: size) == .success
    }
    guard shouldApply() else { return false }
    setEnhancedUserInterface(false, application: write.application)
    defer {
      setEnhancedUserInterface(true, application: write.application)
    }
    return shouldApply() && applySizeValue(write, size: size) == .success
  }

  func applyPosition(
    _ write: AsyncPositionWrite,
    point: CGPoint,
    forceOffscreenAccess: Bool = false,
    verifyParkedPosition: Bool = true,
    enhancedUIManagedByBatch: Bool = false,
    nativePositionIsVerified: (() -> Bool)? = nil,
    shouldApply: () -> Bool = { true }
  ) -> Bool {
    guard shouldApply() else { return false }
    if (write.isParked && verifyParkedPosition) || forceOffscreenAccess {
      if !enhancedUIManagedByBatch {
        setEnhancedUserInterface(false, application: write.application)
      }
      defer {
        if !enhancedUIManagedByBatch, write.enhancedUIWasEnabled {
          setEnhancedUserInterface(true, application: write.application)
        }
      }
      for _ in 0..<2 {
        guard shouldApply() else { return false }
        guard apply(write, point: point) == .success else { continue }
        if nativePositionIsVerified?() == true { return true }
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
      return shouldApply() && apply(write, point: point) == .success
    }
    guard shouldApply() else { return false }
    setEnhancedUserInterface(false, application: write.application)
    defer {
      setEnhancedUserInterface(true, application: write.application)
    }
    return shouldApply() && apply(write, point: point) == .success
  }

  func readPosition(_ element: AXUIElement) -> CGPoint? {
    if let positionReader { return positionReader(element) }
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
    if let positionWriter { return positionWriter(write, point) ? .success : .cannotComplete }
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

  @discardableResult
  func setEnhancedUserInterface(
    _ enabled: Bool,
    application: AXUIElement
  ) -> Bool {
    if let enhancedUIWriter { return enhancedUIWriter(application, enabled) }
    return AXUIElementSetAttributeValue(
      application,
      "AXEnhancedUserInterface" as CFString,
      enabled ? kCFBooleanTrue : kCFBooleanFalse
    ) == .success
  }
}
