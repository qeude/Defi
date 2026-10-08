import ApplicationServices
import DefiModel
import Foundation
import Synchronization
import Testing

@testable import DefiMacOS

@Suite(.serialized)
struct FocusMutationTests {
  private enum Gap: String, CaseIterable {
    case validation, mainAdmission, retryAdmission, foregroundAdmission
    case foregroundRetryAdmission, activationPreparation, inFlightMain
  }

  private struct State {
    var paused = false
    var obsolete = false
    var obsoleteCalls = 0
    var mutations = 0
    var nativeErrors = 0
    var selected = 0
    var timeouts = 0
    var mainCalls = 0
    var foregroundCalls = 0
    var completions: [Int: [NativeFocusCompletion]] = [:]
  }

  private struct Proof {
    let obsoleteCalls: Int
    let mutations: Int
    let nativeErrors: Int
    let selected: Int
    let old: [NativeFocusCompletion]
    let target: [NativeFocusCompletion]
    let carriedRecovery: NativeFocusRecoveryRequest?
  }

  private func request(
    _ pid: pid_t, foreground: Bool = false, input: UserInputTracker? = nil
  ) -> AsyncFocusRequest {
    let element = AXUIElementCreateApplication(pid)
    return AsyncFocusRequest(
      element: element, application: element, processID: pid,
      selectsSpecificWindow: true, validatesSpecificWindowFocus: true,
      activatesApplication: true,
      foregroundWindowElements: foreground ? [AXUIElementCreateApplication(-73)] : [],
      inputGuard: input.map { FocusInputGuard(tracker: $0, maximumTimestamp: 1) },
      recoveryRequest: NativeFocusRecoveryRequest(
        timestamp: 1, excludingWindowID: WindowID(rawValue: 71), excludingProcessID: -71,
        fallback: NativeFocusRecoveryFallback(windowID: WindowID(rawValue: 70), processID: -70)
      )
    )
  }

  private func race(
    _ gap: Gap, newerInput: Bool = false, failTarget: Bool = false,
    explicitCancellation: Bool = false
  ) throws -> Proof {
    let state = Mutex(State())
    let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let oldElement = AXUIElementCreateApplication(-71)
    let foreground = AXUIElementCreateApplication(-73)
    let tracker = UserInputTracker()
    let pause: () -> Void = {
      let shouldPause = state.withLock { value in
        guard !value.paused else { return false }
        value.paused = true
        return true
      }
      if shouldPause {
        entered.signal()
        _ = resume.wait(timeout: .now() + 5)
      }
    }
    let mutate: (AXUIElement, Bool) -> AXError = { element, succeeds in
      state.withLock { value in
        value.mutations += 1
        if !succeeds { value.nativeErrors += 1 }
        let old = CFEqual(element, oldElement) || CFEqual(element, foreground)
        if old && value.obsolete { value.obsoleteCalls += 1 }
        if succeeds && !CFEqual(element, foreground) { value.selected = old ? 71 : 72 }
      }
      return succeeds ? .success : .cannotComplete
    }
    let operations = AXFocusOperations(
      targetIsFocused: { element, _ in
        if gap == .validation && CFEqual(element, oldElement) { pause() }
        return false
      },
      setMain: { element in
        let old = CFEqual(element, oldElement)
        let call = state.withLock { value in value.mainCalls += old ? 1 : 0; return value.mainCalls }
        if old && gap == .inFlightMain { pause() }
        let succeeds = old ? gap != .retryAdmission || call > 1 : !failTarget
        return mutate(element, succeeds)
      },
      raise: { element in
        if CFEqual(element, foreground) {
          let call = state.withLock { value in value.foregroundCalls += 1; return value.foregroundCalls }
          return mutate(element, gap != .foregroundRetryAdmission || call > 1)
        }
        return mutate(element, !CFEqual(element, oldElement) && !failTarget)
      },
      applicationIsActive: { _ in true },
      prepareActivation: {
        if gap == .activationPreparation { pause() }
        return { element in mutate(element, CFEqual(element, oldElement) || !failTarget) }
      },
      activateApplication: { _ in false },
      withTimeout: { _, elements, perform in
        let isForeground = elements.count == 1 && CFEqual(elements[0], foreground)
        let isOld = CFEqual(elements[0], oldElement)
        let ordinal = state.withLock { value in
          if isOld || isForeground { value.timeouts += 1 }
          return value.timeouts
        }
        if (gap == .mainAdmission && isOld && ordinal == 1)
          || (gap == .retryAdmission && isOld && ordinal == 2)
          || (gap == .foregroundAdmission && isForeground && ordinal == 2)
          || (gap == .foregroundRetryAdmission && isForeground && ordinal == 3)
        { pause() }
        perform()
      }
    )
    let writer = AXFocusWriter(operations: operations)
    let oldID = writer.submit(request(-71, foreground: true, input: newerInput ? tracker : nil)) {
      completion in
      state.withLock { $0.completions[71, default: []].append(completion) }
      done.signal()
    }
    let admission = entered.wait(timeout: .now() + 5)
    defer { resume.signal() }
    try #require(admission == .success)
    if newerInput { tracker.recordCapturedCommand(at: 2) }
    if explicitCancellation {
      #expect(writer.cancel(oldID, recoveryFallback:
        NativeFocusRecoveryFallback(windowID: WindowID(rawValue: 69), processID: -69)))
    }
    state.withLock { $0.obsolete = true }
    if !newerInput && !explicitCancellation {
      writer.submit(request(-72)) { completion in
        state.withLock { $0.completions[72, default: []].append(completion) }
        done.signal()
      }
    }
    resume.signal()
    try #require(done.wait(timeout: .now() + 5) == .success)
    if !newerInput && !explicitCancellation {
      try #require(done.wait(timeout: .now() + 5) == .success)
    }
    writer.queue.sync {}
    #expect(!writer.isBusy)
    return state.withLock {
      Proof(obsoleteCalls: $0.obsoleteCalls, mutations: $0.mutations,
        nativeErrors: $0.nativeErrors, selected: $0.selected,
        old: $0.completions[71] ?? [], target: $0.completions[72] ?? [],
        carriedRecovery: writer.carriedFocusRecovery)
    }
  }

  @Test func supersessionRejectsMutationsAfterBlockingAdmission() throws {
    for gap in Gap.allCases where gap != .inFlightMain {
      let proof = try race(gap)
      #expect(proof.obsoleteCalls == 0)
      #expect(proof.selected == 72)
      #expect(proof.old.count == 1)
      #expect(proof.old.first?.result ==
        ([.foregroundAdmission, .foregroundRetryAdmission, .activationPreparation].contains(gap)
          ? .supersededAfterMutation : .superseded))
      #expect(proof.old.first?.recoveryRequest == nil)
      #expect(proof.target == [NativeFocusCompletion(result: .completed, recoveryRequest: nil)])
      #expect(proof.carriedRecovery == nil)
    }
  }

  @Test func newerInputRejectsMutationsAndDoesNotFabricateSuccess() throws {
    for gap in [Gap.validation, .mainAdmission, .retryAdmission, .activationPreparation] {
      let proof = try race(gap, newerInput: true)
      #expect(proof.obsoleteCalls == 0)
      #expect(proof.old.count == 1)
      #expect(proof.old.first?.result ==
        (gap == .activationPreparation ? .cancelledAfterInputMutation : .cancelled))
      #expect(proof.selected == (gap == .activationPreparation ? 71 : 0))
      #expect(proof.target.isEmpty)
      if gap == .activationPreparation {
        #expect(proof.old.first?.recoveryRequest?.fallback?.windowID == WindowID(rawValue: 70))
      }
    }
  }

  @Test func inFlightMutationTransfersRecoveryExactlyOnce() throws {
    let proof = try race(.inFlightMain, failTarget: true)
    #expect(proof.selected == 71)
    #expect(proof.old == [NativeFocusCompletion(result: .supersededAfterMutation, recoveryRequest: nil)])
    #expect(proof.target.count == 1)
    #expect(proof.target.first?.result == .failed)
    #expect(proof.target.first?.recoveryRequest?.fallback?.windowID == WindowID(rawValue: 70))
    #expect(proof.target.first?.recoveryRequest?.excludingProcessID == -71)
    #expect(proof.carriedRecovery == nil)
  }

  @Test func explicitInFlightCancellationRetainsRecoveryFallback() throws {
    let proof = try race(.inFlightMain, explicitCancellation: true)
    #expect(proof.selected == 71)
    #expect(proof.old == [NativeFocusCompletion(result: .cancelledAfterInputMutation,
      recoveryRequest: NativeFocusRecoveryRequest(
        timestamp: 1, excludingWindowID: WindowID(rawValue: 71), excludingProcessID: -71,
        fallback: NativeFocusRecoveryFallback(windowID: WindowID(rawValue: 69), processID: -69),
        fallbackOnlyIfNoNewerInput: true
      ))])
    #expect(proof.target.isEmpty)
    #expect(proof.carriedRecovery == nil)
  }

  @Test func explicitCancellationAtAdmissionPreventsNativeFocus() throws {
    let proof = try race(.mainAdmission, explicitCancellation: true)
    #expect(proof.selected == 0)
    #expect(proof.obsoleteCalls == 0)
    #expect(proof.old == [NativeFocusCompletion(result: .cancelled, recoveryRequest: nil)])
    #expect(proof.carriedRecovery == nil)
  }

  @Test func performanceFocus() throws {
    guard ProcessInfo.processInfo.environment["DEFI_PERF_JSON"] == "1" else { return }
    var obsolete = 0, mutations = 0, completed = 0, errors = 0, supersessions = 0
    var nativeErrors = 0
    for _ in 0..<8 {
      for gap in Gap.allCases where gap != .inFlightMain {
        let proof = try race(gap)
        obsolete += proof.obsoleteCalls
        mutations += proof.mutations
        nativeErrors += proof.nativeErrors
        completed += proof.old.count + proof.target.count
        if proof.old.first?.result == .superseded
          || proof.old.first?.result == .supersededAfterMutation { supersessions += 1 }
        if proof.selected != 72 || proof.old.count != 1
          || proof.target != [NativeFocusCompletion(result: .completed, recoveryRequest: nil)]
          || proof.carriedRecovery != nil
        { errors += 1 }
      }
    }
    #expect(errors == 0)
    #expect(supersessions == 48)
    #expect(nativeErrors == 24)
    try emit("focus-races", operations: completed, errors: errors,
      output: ["final_target": 72, "completions": completed, "races": 48,
        "supersessions": supersessions, "pending_recoveries": 0],
      metrics: ["obsolete_mutations": Double(obsolete), "native_mutations": Double(mutations),
        "expected_injected_ax_errors": Double(nativeErrors)])

    let selected = Mutex(0), calls = Mutex(0), done = DispatchSemaphore(value: 0)
    let failures = Mutex(0)
    let writer = AXFocusWriter(operations: AXFocusOperations(
      targetIsFocused: { _, _ in false },
      setMain: { _ in selected.withLock { $0 = 72 }; calls.withLock { $0 += 1 }; return .success },
      raise: { _ in calls.withLock { $0 += 1 }; return .success },
      applicationIsActive: { _ in true },
      prepareActivation: { { _ in calls.withLock { $0 += 1 }; return .success } },
      activateApplication: { _ in true },
      withTimeout: { _, _, perform in perform() }
    ))
    let target = request(-72)
    let start = ProcessInfo.processInfo.systemUptime
    for _ in 0..<512 {
      writer.submit(target) { completion in
        if completion != NativeFocusCompletion(result: .completed, recoveryRequest: nil) {
          failures.withLock { $0 += 1 }
        }
        done.signal()
      }
      try #require(done.wait(timeout: .now() + 5) == .success)
    }
    writer.queue.sync {}
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    #expect(selected.withLock { $0 } == 72)
    #expect(calls.withLock { $0 } == 1024)
    #expect(failures.withLock { $0 } == 0)
    try emit("focus-ordinary", operations: 512, errors: failures.withLock { $0 },
      output: ["final_target": 72, "completions": 512, "native_mutations": calls.withLock { $0 }],
      metrics: ["elapsed_ms": elapsed])
  }

  private func emit(
    _ name: String, operations: Int, errors: Int, output: [String: Int], metrics: [String: Double]
  ) throws {
    let data = try JSONSerialization.data(withJSONObject: ["case": name,
      "operations": operations, "errors": errors, "output": output, "metrics": metrics])
    print("DEFI_PERF_JSON " + String(decoding: data, as: UTF8.self))
  }
}
