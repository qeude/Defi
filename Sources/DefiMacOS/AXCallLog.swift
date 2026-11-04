import ApplicationServices
import Foundation
import Synchronization

/// One Accessibility focus call as macOS answered it: the operation, which window it targeted,
/// the result and how long macOS took. A desktop run and a simulated run of the same scenario
/// produce comparable logs, so the simulated macOS can be checked against the real one.
public struct AXCall: Codable, Equatable, Sendable {
  public var operation: String
  public var target: String
  public var result: String
  public var milliseconds: Double
}

public final class AXCallLog: Sendable {
  private let calls = Mutex<[AXCall]>([])
  /// Names the window or application an element is, such as "requested" or "other".
  private let label: @Sendable (AXUIElement) -> String

  public init(label: @escaping @Sendable (AXUIElement) -> String) {
    self.label = label
  }

  public var entries: [AXCall] { calls.withLock { $0 } }

  public func reset() { calls.withLock { $0.removeAll() } }

  func record<Result>(_ operation: String, _ element: AXUIElement?, _ body: () -> Result) -> Result {
    let started = DispatchTime.now().uptimeNanoseconds
    let result = body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    let call = AXCall(
      operation: operation, target: element.map(label) ?? "-", result: "\(result)", milliseconds: elapsed
    )
    calls.withLock { $0.append(call) }
    return result
  }
}

extension AXFocusOperations {
  /// The same operations, each call recorded in `log`.
  func recording(into log: AXCallLog) -> AXFocusOperations {
    var recorded = self
    let base = self
    recorded.targetIsFocused = { element, application in
      log.record("targetIsFocused", element) { base.targetIsFocused(element, application) }
    }
    recorded.setMain = { element in log.record("setMain", element) { base.setMain(element) } }
    recorded.raise = { element in log.record("raise", element) { base.raise(element) } }
    recorded.prepareActivation = {
      let activate = base.prepareActivation()
      return { application in log.record("setFocusedApplication", application) { activate(application) } }
    }
    recorded.activateApplication = { processID in
      log.record("activateApplication", nil) { base.activateApplication(processID) }
    }
    return recorded
  }
}
