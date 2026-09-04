import AppKit
import CoreFoundation
import Darwin
import DefiCore
import DefiModel

func normalizedWindowBorderFrame(_ bounds: CGRect) -> Rect? {
  guard bounds.origin.x.isFinite,
    bounds.origin.y.isFinite,
    bounds.size.width.isFinite,
    bounds.size.height.isFinite,
    bounds.size.width > 0,
    bounds.size.height > 0
  else {
    return nil
  }
  return Rect(
    x: Double(bounds.origin.x),
    y: Double(bounds.origin.y),
    width: Double(bounds.size.width),
    height: Double(bounds.size.height)
  )
}

struct WindowWidthConstraints: Equatable, Sendable {
  let minimum: Double?
  let maximum: Double?
}

func normalizedWindowWidthConstraints(
  minimum: CGFloat,
  maximum: CGFloat
) -> WindowWidthConstraints {
  let minimum = minimum.isFinite && minimum > 0 ? Double(minimum) : nil
  var maximum =
    maximum.isFinite && maximum > 0 && maximum < 100_000
    ? Double(maximum)
    : nil
  if let minimum, let value = maximum, value < minimum {
    maximum = minimum
  }
  return WindowWidthConstraints(minimum: minimum, maximum: maximum)
}

func windowBorderFrameSnapshot(
  windowIDs: Set<WindowID>,
  frameProvider: (WindowID) -> Rect?
) -> [WindowID: Rect] {
  Dictionary(
    uniqueKeysWithValues: windowIDs.compactMap { windowID in
      frameProvider(windowID).map { (windowID, $0) }
    }
  )
}

final class WindowServerBoundsProvider {
  private typealias MainConnectionIDFunc = @convention(c) () -> Int32
  private typealias GetWindowBoundsFunc =
    @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
  private typealias WindowQueryFunc =
    @convention(c) (Int32, UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
  private typealias QueryCopyWindowsFunc =
    @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
  private typealias IteratorCountFunc = @convention(c) (UnsafeRawPointer?) -> Int32
  private typealias IteratorAdvanceFunc = @convention(c) (UnsafeRawPointer?) -> Bool
  private typealias IteratorWindowIDFunc = @convention(c) (UnsafeRawPointer?) -> UInt32
  private typealias IteratorConstraintsFunc =
    @convention(c) (
      UnsafeRawPointer?,
      UnsafeMutablePointer<CGSize>,
      UnsafeMutablePointer<CGSize>,
      UnsafeMutablePointer<CGSize>
    ) -> Void

  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let getWindowBounds: GetWindowBoundsFunc?
  private let windowQuery: WindowQueryFunc?
  private let queryCopyWindows: QueryCopyWindowsFunc?
  private let iteratorCount: IteratorCountFunc?
  private let iteratorAdvance: IteratorAdvanceFunc?
  private let iteratorWindowID: IteratorWindowIDFunc?
  private let iteratorConstraints: IteratorConstraintsFunc?
  private(set) var successfulLookupCount = 0
  private(set) var failureCount = 0
  private(set) var successfulConstraintLookupCount = 0
  private(set) var constraintFallbackCount = 0
  private var disabled = false
  private var probeSucceeded = false
  private var constraintProbeSucceeded = false
  private var constraintsDisabled = false
  private var constraintCache: [WindowID: WindowWidthConstraints] = [:]

  func probe(ownedWindowID: WindowID) {
    guard let rawWindowID = UInt32(exactly: ownedWindowID.rawValue) else {
      disabled = true
      constraintsDisabled = true
      failureCount += 1
      constraintFallbackCount += 1
      return
    }
    if !probeSucceeded, !disabled {
      var bounds = CGRect.zero
      if let mainConnectionID, let getWindowBounds,
        getWindowBounds(mainConnectionID(), rawWindowID, &bounds) == 0,
        normalizedWindowBorderFrame(bounds) != nil
      {
        probeSucceeded = true
      } else {
        disabled = true
        failureCount += 1
      }
    }
    if !constraintProbeSucceeded, !constraintsDisabled {
      if rawConstraints(for: rawWindowID) != nil {
        constraintProbeSucceeded = true
      } else {
        constraintsDisabled = true
        constraintFallbackCount += 1
      }
    }
  }

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle

    func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
      guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }

    mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
    getWindowBounds = resolve("SLSGetWindowBounds", as: GetWindowBoundsFunc.self)
    windowQuery = resolve("SLSWindowQueryWindows", as: WindowQueryFunc.self)
    queryCopyWindows = resolve(
      "SLSWindowQueryResultCopyWindows",
      as: QueryCopyWindowsFunc.self
    )
    iteratorCount = resolve("SLSWindowIteratorGetCount", as: IteratorCountFunc.self)
    iteratorAdvance = resolve(
      "SLSWindowIteratorAdvance",
      as: IteratorAdvanceFunc.self
    )
    iteratorWindowID = resolve(
      "SLSWindowIteratorGetWindowID",
      as: IteratorWindowIDFunc.self
    )
    iteratorConstraints = resolve(
      "SLSWindowIteratorGetConstraints",
      as: IteratorConstraintsFunc.self
    )
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  func frame(for windowID: WindowID) -> Rect? {
    guard !disabled, probeSucceeded else { return nil }
    guard let rawWindowID = UInt32(exactly: windowID.rawValue),
      let mainConnectionID,
      let getWindowBounds
    else {
      return nil
    }
    var bounds = CGRect.zero
    guard getWindowBounds(mainConnectionID(), rawWindowID, &bounds) == 0 else {
      disabled = true
      failureCount += 1
      return nil
    }
    guard let frame = normalizedWindowBorderFrame(bounds) else {
      disabled = true
      failureCount += 1
      return nil
    }
    successfulLookupCount += 1
    return frame
  }

  func widthConstraints(for windowID: WindowID) -> WindowWidthConstraints? {
    guard !constraintsDisabled, constraintProbeSucceeded else {
      constraintFallbackCount += 1
      return nil
    }
    if let cached = constraintCache[windowID] { return cached }
    guard let rawWindowID = UInt32(exactly: windowID.rawValue),
      let (minimum, maximum, _) = rawConstraints(for: rawWindowID)
    else {
      constraintsDisabled = true
      constraintCache.removeAll(keepingCapacity: false)
      constraintFallbackCount += 1
      return nil
    }
    let constraints = normalizedWindowWidthConstraints(
      minimum: minimum.width,
      maximum: maximum.width
    )
    constraintCache[windowID] = constraints
    successfulConstraintLookupCount += 1
    return constraints
  }

  func retainConstraints(for windowIDs: Set<WindowID>) {
    constraintCache = constraintCache.filter { windowIDs.contains($0.key) }
  }

  private func rawConstraints(
    for rawWindowID: UInt32
  ) -> (CGSize, CGSize, CGSize)? {
    guard let mainConnectionID,
      let windowQuery,
      let queryCopyWindows,
      let iteratorCount,
      let iteratorAdvance,
      let iteratorWindowID,
      let iteratorConstraints
    else { return nil }
    let windowIDs = NSArray(object: NSNumber(value: rawWindowID))
    let query = windowQuery(
      mainConnectionID(),
      Unmanaged.passUnretained(windowIDs).toOpaque(),
      0
    )
    guard let query else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(query).release() }
    guard let iterator = queryCopyWindows(query) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(iterator).release() }
    guard iteratorCount(iterator) > 0,
      iteratorAdvance(iterator),
      iteratorWindowID(iterator) == rawWindowID
    else { return nil }
    var minimum = CGSize.zero
    var maximum = CGSize.zero
    var current = CGSize.zero
    iteratorConstraints(iterator, &minimum, &maximum, &current)
    return (minimum, maximum, current)
  }

  var isAvailable: Bool {
    !disabled && probeSucceeded && mainConnectionID != nil && getWindowBounds != nil
  }

  var constraintsAreAvailable: Bool {
    !constraintsDisabled && constraintProbeSucceeded
  }
}

final class WindowCornerRadiusProvider {
  private typealias MainConnectionIDFunc = @convention(c) () -> Int32
  private typealias WindowQueryFunc =
    @convention(c) (Int32, UnsafeRawPointer?, UInt32) -> UnsafeMutableRawPointer?
  private typealias QueryCopyWindowsFunc =
    @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
  private typealias IteratorCountFunc = @convention(c) (UnsafeRawPointer?) -> Int32
  private typealias IteratorAdvanceFunc = @convention(c) (UnsafeRawPointer?) -> Bool
  private typealias IteratorCornerRadiiFunc =
    @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?

  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let windowQuery: WindowQueryFunc?
  private let queryCopyWindows: QueryCopyWindowsFunc?
  private let iteratorCount: IteratorCountFunc?
  private let iteratorAdvance: IteratorAdvanceFunc?
  private let iteratorCornerRadii: IteratorCornerRadiiFunc?
  private var cache: [WindowID: Double] = [:]

  init() {
    let handle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL
    )
    libraryHandle = handle

    func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
      guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
      return unsafeBitCast(pointer, to: T.self)
    }

    mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
    windowQuery = resolve("SLSWindowQueryWindows", as: WindowQueryFunc.self)
    queryCopyWindows = resolve(
      "SLSWindowQueryResultCopyWindows",
      as: QueryCopyWindowsFunc.self
    )
    iteratorCount = resolve("SLSWindowIteratorGetCount", as: IteratorCountFunc.self)
    iteratorAdvance = resolve(
      "SLSWindowIteratorAdvance",
      as: IteratorAdvanceFunc.self
    )
    iteratorCornerRadii = resolve(
      "SLSWindowIteratorGetCornerRadii",
      as: IteratorCornerRadiiFunc.self
    )
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  func retain(windowIDs: Set<WindowID>) {
    cache = cache.filter { windowIDs.contains($0.key) }
  }

  func radius(for windowID: WindowID) -> Double {
    if let cached = cache[windowID] { return cached }
    let radius = resolvedWindowBorderRadius(
      nativeRadius: readRadius(for: windowID)
    )
    cache[windowID] = radius
    return radius
  }

  private func readRadius(for windowID: WindowID) -> Double? {
    guard let rawWindowID = UInt32(exactly: windowID.rawValue),
      let mainConnectionID,
      let windowQuery,
      let queryCopyWindows,
      let iteratorCount,
      let iteratorAdvance,
      let iteratorCornerRadii
    else {
      return nil
    }
    let windowIDs = NSArray(object: NSNumber(value: rawWindowID))
    let windowIDsPointer = Unmanaged.passUnretained(windowIDs).toOpaque()
    guard let query = windowQuery(mainConnectionID(), windowIDsPointer, 0) else {
      return nil
    }
    defer { Unmanaged<AnyObject>.fromOpaque(query).release() }
    guard let iterator = queryCopyWindows(query) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(iterator).release() }
    guard iteratorCount(iterator) > 0, iteratorAdvance(iterator) else { return nil }
    guard let radii = iteratorCornerRadii(iterator) else { return nil }
    defer { Unmanaged<AnyObject>.fromOpaque(radii).release() }
    let values = Unmanaged<CFArray>.fromOpaque(radii).takeUnretainedValue()
    guard CFArrayGetCount(values) > 0,
      let rawValue = CFArrayGetValueAtIndex(values, 0)
    else {
      return nil
    }
    let value = Unmanaged<NSNumber>.fromOpaque(
      UnsafeMutableRawPointer(mutating: rawValue)
    ).takeUnretainedValue().doubleValue
    return value > 0 && value.isFinite ? value : nil
  }
}
