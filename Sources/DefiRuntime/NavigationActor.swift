import Dispatch

/// Serial ownership of navigation state. Native I/O and AppKit execute elsewhere.
/// Enqueue callback messages directly to preserve their arrival order.
@globalActor
public actor NavigationActor {
  public static let shared = NavigationActor()
  public nonisolated let queue = DispatchSerialQueue(
    label: "com.quentin.defi.navigation", qos: .userInteractive
  )
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  /// Like MainActor.assumeIsolated, bridge a synchronous Dispatch callback only
  /// after the runtime verifies that it is executing on our serial executor.
  public nonisolated static func assumeIsolated<T>(
    _ operation: @NavigationActor () throws -> T
  ) rethrows -> T {
    shared.preconditionIsolated()
    return try withoutActuallyEscaping(operation) { isolatedOperation in
      try unsafeBitCast(isolatedOperation, to: (() throws -> T).self)()
    }
  }

  public nonisolated static func enqueue(
    _ operation: @escaping @NavigationActor @Sendable () -> Void
  ) {
    shared.queue.async {
      assumeIsolated(operation)
    }
  }
}
