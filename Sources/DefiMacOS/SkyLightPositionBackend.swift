import CoreGraphics
import Darwin
import Foundation
import OSLog

private let skyLightLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "SkyLight"
)

enum PositionAnimationBackend: Equatable, Sendable {
  case accessibility
  case skyLight
}

func selectPositionAnimationBackend(
  experimentalSkyLightEnabled: Bool,
  skyLightAvailable: Bool,
  animatedPositionFrame: Bool,
  containsParkedWrite: Bool,
  containsSizeChange: Bool,
  containsVerticalMove: Bool
) -> PositionAnimationBackend {
  guard experimentalSkyLightEnabled,
    skyLightAvailable,
    animatedPositionFrame,
    containsParkedWrite == false,
    containsSizeChange == false,
    containsVerticalMove == false
  else {
    return .accessibility
  }
  return .skyLight
}

struct SkyLightPositionMove: Sendable {
  let windowID: UInt32
  let point: CGPoint
}

public struct SkyLightPositionPerformance: Equatable, Sendable {
  public let state: String
  public let batches: Int
  public let moves: Int
  public let failures: Int
  public let fallbacks: Int
  public let lastDurationMS: Double
  public let maximumDurationMS: Double
  public let probeVerified: Bool
}

final class SkyLightPositionBackend: @unchecked Sendable {
  private typealias MainConnectionIDFunc = @convention(c) () -> Int32
  private typealias TransactionCreateFunc =
    @convention(c) (Int32) -> UnsafeMutableRawPointer?
  private typealias TransactionSetWindowTransformFunc =
    @convention(c) (
      UnsafeMutableRawPointer,
      UInt32,
      Int32,
      Int32,
      CGAffineTransform
    ) -> CGError
  private typealias TransactionCommitFunc =
    @convention(c) (UnsafeMutableRawPointer, Int32) -> CGError
  private typealias GetWindowTransformFunc =
    @convention(c) (
      Int32,
      UInt32,
      UnsafeMutablePointer<CGAffineTransform>
    ) -> CGError

  private enum State {
    case ready
    case unavailable(String)
    case tripped(String)

    var description: String {
      switch self {
      case .ready:
        "ready"
      case .unavailable(let reason):
        "unavailable:\(reason)"
      case .tripped(let reason):
        "tripped:\(reason)"
      }
    }
  }

  private let lock = NSLock()
  private let libraryHandle: UnsafeMutableRawPointer?
  private let mainConnectionID: MainConnectionIDFunc?
  private let transactionCreate: TransactionCreateFunc?
  private let transactionSetWindowTransform: TransactionSetWindowTransformFunc?
  private let transactionCommit: TransactionCommitFunc?
  private let getWindowTransform: GetWindowTransformFunc?
  private var state: State
  private var consecutiveFailures = 0
  private var batches = 0
  private var moves = 0
  private var failures = 0
  private var fallbacks = 0
  private var lastDurationMS = 0.0
  private var maximumDurationMS = 0.0
  private var probeVerified = false
  private var transformedWindowIDs = Set<UInt32>()

  init() {
    let libraryHandle = dlopen(
      "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL
    )
    self.libraryHandle = libraryHandle

    func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
      guard let libraryHandle,
        let pointer = dlsym(libraryHandle, symbol)
      else {
        return nil
      }
      return unsafeBitCast(pointer, to: T.self)
    }

    mainConnectionID = resolve("SLSMainConnectionID", as: MainConnectionIDFunc.self)
    transactionCreate = resolve(
      "SLSTransactionCreate",
      as: TransactionCreateFunc.self
    )
    transactionSetWindowTransform = resolve(
      "SLSTransactionSetWindowTransform",
      as: TransactionSetWindowTransformFunc.self
    )
    transactionCommit = resolve(
      "SLSTransactionCommit",
      as: TransactionCommitFunc.self
    )
    getWindowTransform = resolve(
      "SLSGetWindowTransform",
      as: GetWindowTransformFunc.self
    )

    var missing: [String] = []
    if libraryHandle == nil { missing.append("SkyLight") }
    if mainConnectionID == nil { missing.append("SLSMainConnectionID") }
    if transactionCreate == nil {
      missing.append("SLSTransactionCreate")
    }
    if transactionSetWindowTransform == nil {
      missing.append("SLSTransactionSetWindowTransform")
    }
    if transactionCommit == nil {
      missing.append("SLSTransactionCommit")
    }
    if getWindowTransform == nil {
      missing.append("SLSGetWindowTransform")
    }

    if missing.isEmpty {
      state = .ready
      skyLightLogger.info("experimental position backend ready")
    } else {
      state = .unavailable(missing.joined(separator: ","))
      skyLightLogger.error(
        "experimental position backend unavailable symbols=\(missing.joined(separator: ","), privacy: .public)"
      )
    }
  }

  deinit {
    if let libraryHandle {
      dlclose(libraryHandle)
    }
  }

  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    if case .ready = state {
      return true
    }
    return false
  }

  func apply(
    _ requestedMoves: [SkyLightPositionMove],
    verifyReadback: Bool = false
  ) -> Bool {
    let requestedMoves = requestedMoves.sorted { $0.windowID < $1.windowID }
    guard requestedMoves.isEmpty == false else { return true }

    lock.lock()
    guard case .ready = state else {
      fallbacks += 1
      lock.unlock()
      return false
    }
    lock.unlock()
    return applyTransforms(
      requestedMoves,
      verifyReadback: verifyReadback
    )
  }

  private func applyTransforms(
    _ requestedMoves: [SkyLightPositionMove],
    verifyReadback: Bool
  ) -> Bool {
    guard let mainConnectionID,
      let transactionCreate,
      let transactionSetWindowTransform,
      let transactionCommit
    else {
      recordFailure("missing-transform-symbol", tripImmediately: true)
      return false
    }
    let connectionID = mainConnectionID()
    guard connectionID != 0 else {
      recordFailure("transform-connection")
      return false
    }
    let startedAt = ProcessInfo.processInfo.systemUptime
    let windowIDs = requestedMoves.map(\.windowID)
    let transforms = requestedMoves.map {
      CGAffineTransform(
        translationX: -$0.point.x,
        y: -$0.point.y
      )
    }
    guard let transaction = transactionCreate(connectionID) else {
      recordFailure("transform-transaction-create")
      return false
    }
    defer {
      Unmanaged<AnyObject>.fromOpaque(transaction).release()
    }
    for (windowID, transform) in zip(
      windowIDs,
      transforms
    ) {
      // SkyLight return values vary across macOS builds. Readback below is
      // authoritative for the final frame.
      _ = transactionSetWindowTransform(
        transaction,
        windowID,
        0,
        0,
        transform
      )
    }
    _ = transactionCommit(transaction, 0)
    lock.lock()
    transformedWindowIDs.formUnion(windowIDs)
    lock.unlock()

    if verifyReadback {
      for (move, transform) in zip(requestedMoves, transforms) {
        guard
          verifyTransform(
            windowID: move.windowID,
            expected: transform,
            connectionID: connectionID
          )
        else {
          recordFailure(
            "transform-readback-mismatch",
            tripImmediately: false
          )
          return false
        }
      }
      if needsProbeVerification,
        let firstWindowID = requestedMoves.first?.windowID
      {
        lock.lock()
        probeVerified = true
        lock.unlock()
        skyLightLogger.info(
          "experimental transform backend verified window=\(firstWindowID, privacy: .public)"
        )
      }
    }

    let durationMS =
      (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
    lock.lock()
    consecutiveFailures = 0
    batches += 1
    moves += requestedMoves.count
    lastDurationMS = durationMS
    maximumDurationMS = max(maximumDurationMS, durationMS)
    lock.unlock()
    return true
  }

  func alignIfManaged(_ move: SkyLightPositionMove) {
    lock.lock()
    let isManaged = transformedWindowIDs.contains(
      move.windowID
    )
    lock.unlock()
    guard isManaged,
      let mainConnectionID,
      let transactionCreate,
      let transactionSetWindowTransform,
      let transactionCommit
    else {
      return
    }
    let connectionID = mainConnectionID()
    guard connectionID != 0 else { return }
    let transform = CGAffineTransform(
      translationX: -move.point.x,
      y: -move.point.y
    )
    guard let transaction = transactionCreate(connectionID) else {
      return
    }
    defer {
      Unmanaged<AnyObject>.fromOpaque(transaction).release()
    }
    guard transactionSetWindowTransform(
      transaction,
      move.windowID,
      0,
      0,
      transform
    ) == .success
    else {
      return
    }
    _ = transactionCommit(transaction, 0)
  }

  private func verifyTransform(
    windowID: UInt32,
    expected: CGAffineTransform,
    connectionID: Int32
  ) -> Bool {
    guard let getWindowTransform else { return false }
    let attemptCount = 2
    var lastTransform = CGAffineTransform.identity
    var lastError = CGError.failure
    for attempt in 0..<attemptCount {
      var transform = CGAffineTransform.identity
      let error = getWindowTransform(
        connectionID,
        windowID,
        &transform
      )
      lastTransform = transform
      lastError = error
      if error == .success,
        abs(transform.tx - expected.tx) <= 2,
        abs(transform.ty - expected.ty) <= 2,
        abs(transform.a - expected.a) <= 0.01,
        abs(transform.d - expected.d) <= 0.01
      {
        return true
      }
      if attempt < attemptCount - 1 {
        usleep(250)
      }
    }
    skyLightLogger.error(
      "transform mismatch window=\(windowID, privacy: .public) expected=\(expected.tx, privacy: .public),\(expected.ty, privacy: .public) actual=\(lastTransform.tx, privacy: .public),\(lastTransform.ty, privacy: .public) error=\(lastError.rawValue, privacy: .public)"
    )
    return false
  }

  func recordFallback() {
    lock.lock()
    fallbacks += 1
    lock.unlock()
  }

  var performance: SkyLightPositionPerformance {
    lock.lock()
    defer { lock.unlock() }
    return SkyLightPositionPerformance(
      state: "\(state.description):transaction-transform",
      batches: batches,
      moves: moves,
      failures: failures,
      fallbacks: fallbacks,
      lastDurationMS: lastDurationMS,
      maximumDurationMS: maximumDurationMS,
      probeVerified: probeVerified
    )
  }

  private var needsProbeVerification: Bool {
    lock.lock()
    defer { lock.unlock() }
    return probeVerified == false
  }

  private func recordFailure(
    _ reason: String,
    tripImmediately: Bool = false
  ) {
    lock.lock()
    failures += 1
    fallbacks += 1
    consecutiveFailures += 1
    let shouldTrip = tripImmediately || consecutiveFailures >= 3
    if shouldTrip {
      state = .tripped(reason)
    }
    let failureCount = consecutiveFailures
    lock.unlock()

    if shouldTrip {
      skyLightLogger.fault(
        "experimental position backend circuit opened reason=\(reason, privacy: .public)"
      )
    } else {
      skyLightLogger.error(
        "experimental position backend fallback reason=\(reason, privacy: .public) consecutive=\(failureCount)"
      )
    }
  }
}
