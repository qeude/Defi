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

  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let getWindowBounds: GetWindowBoundsFunc?
  private(set) var successfulLookupCount = 0
  private(set) var failureCount = 0
  private var disabled = false
  private var probeSucceeded = false

  func probe(ownedWindowID: WindowID) {
    guard !probeSucceeded, !disabled else { return }
    guard let rawWindowID = UInt32(exactly: ownedWindowID.rawValue),
      let mainConnectionID,
      let getWindowBounds
    else {
      disabled = true
      failureCount += 1
      return
    }
    var bounds = CGRect.zero
    guard getWindowBounds(mainConnectionID(), rawWindowID, &bounds) == 0,
      normalizedWindowBorderFrame(bounds) != nil
    else {
      disabled = true
      failureCount += 1
      return
    }
    probeSucceeded = true
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

  var isAvailable: Bool {
    !disabled && probeSucceeded && mainConnectionID != nil && getWindowBounds != nil
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
