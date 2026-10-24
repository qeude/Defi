import AppKit
import ApplicationServices
import Darwin
import DefiConfig
import DefiCore
import DefiModel
import OSLog


extension AXFrameCoordinator {
  func drain() {
    while true {
      lock.lock()
      guard let queuedFrame = pending else {
        running = false
        lock.unlock()
        return
      }
      pending = nil
      let (frame, rebasedWindowCount) =
        rebaseFrameToCompletedPositionsLocked(queuedFrame)
      let applicationCount = Set(frame.writes.values.map(\.processID)).count
      activeWindowIDs = Set(frame.writes.keys)
      activeWrites = frame.writes
      appendTraceLocked(
        "start g=\(frame.generation) apps=\(applicationCount) rebased=\(rebasedWindowCount)"
      )
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let result = applyFrame(frame, skippedProcesses: [])
      let aborted = !isCurrent(generation: frame.generation)
      let elapsedMS =
        (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
      lock.lock()
      completedWrites += result.applied
      skippedStaleWrites += result.stale
      lastFrameDurationMS = elapsedMS
      maximumFrameDurationMS = max(maximumFrameDurationMS, elapsedMS)
      if elapsedMS > 16.67 {
        slowFrameCount += 1
      }
      appendTraceLocked(
        "\(aborted ? "abort" : "complete") g=\(frame.generation) applied=\(result.applied) ms=\(String(format: "%.2f", elapsedMS))"
      )
      let successfulWindowIDs =
        successfulFinalWritesByGeneration.removeValue(
          forKey: frame.generation
        ) ?? []
      reportedSuccessfulWriteWindowIDsByGeneration[frame.generation] = nil
      if !aborted {
        for windowID in frame.writes.keys {
          latestWriteSucceededByWindowID[windowID] =
            successfulWindowIDs.contains(windowID)
        }
      }
      activeWindowIDs.removeAll(keepingCapacity: true)
      activeWrites.removeAll(keepingCapacity: true)
      retireIdleProcessWriteQueuesLocked()
      lock.unlock()
      let acceptedObservations = readAcceptedFrames(
        for: frame,
        successfulWindowIDs: successfulWindowIDs
      )
      let completedLatest = !aborted && isCurrent(generation: frame.generation)
      frame.completion?(
        FrameWriteCompletion(
          completedLatest: completedLatest,
          attemptedWindowIDs: Set(frame.writes.keys),
          successfulWindowIDs: successfulWindowIDs,
          acceptedObservations: completedLatest ? acceptedObservations : []
        )
      )
    }
  }

  func rebaseFrameToCompletedPositionsLocked(
    _ frame: QueuedPositionFrame
  ) -> (frame: QueuedPositionFrame, count: Int) {
    var writes = frame.writes
    var count = 0
    for (windowID, write) in frame.writes {
      let completedPoint = completedPositions[windowID]
      let completedSize = completedSizes[windowID]
      let rebasesPosition =
        completedPoint.map {
          accessibilityWriter.pointDistance($0, write.fromPoint) >= 0.5
        } ?? false
      let rebasesSize =
        completedSize.map {
          abs($0.width - write.fromSize.width) >= 0.5
            || abs($0.height - write.fromSize.height) >= 0.5
        } ?? false
      guard rebasesPosition || rebasesSize else { continue }
      writes[windowID] = AsyncPositionWrite(
        element: write.element,
        application: write.application,
        processID: write.processID,
        fromPoint: completedPoint ?? write.fromPoint,
        point: write.point,
        fromSize: completedSize ?? write.fromSize,
        size: write.size,
        positionChanged: write.positionChanged,
        sizeChanged: write.sizeChanged,
        synchronousSizeWriteSucceeded: write.synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: write.enhancedUIWasEnabled,
        timeoutSeconds: write.timeoutSeconds,
        isParked: write.isParked,
        requiresVerifiedOffscreenWrite: write.requiresVerifiedOffscreenWrite,
        binding: write.binding
      )
      count += 1
    }
    guard count > 0 else { return (frame, 0) }
    return (
      QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: writes,
        monitorFrames: frame.monitorFrames,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        successfulWrite: frame.successfulWrite,
        completion: frame.completion,
        cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
      ),
      count
    )
  }
}
