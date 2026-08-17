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
      activeAnimationRunning = frame.animationDuration > 0
      activeWindowIDs = Set(frame.writes.keys)
      activeWrites = frame.writes
      activeAnimatedWindowIDs = frame.animatedWindowIDs
      activeAnimatedSizeWindowIDs = Set(
        frame.writes.compactMap { windowID, write in
          frame.animatedWindowIDs.contains(windowID) && write.animatesSize
            ? windowID
            : nil
        }
      )
      appendTraceLocked(
        "start g=\(frame.generation) apps=\(applicationCount) rebased=\(rebasedWindowCount)"
      )
      lock.unlock()

      let startedAt = ProcessInfo.processInfo.systemUptime
      let result: (applied: Int, stale: Int, frames: Int)
      if frame.animationDuration > 0 {
        result = animate(frame)
      } else {
        let appliedFrame = applyFrame(
          frame,
          progress: 1,
          skippedProcesses: []
        )
        result = (
          appliedFrame.applied,
          appliedFrame.stale,
          appliedFrame.frames
        )
      }
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
      lastAnimationFrameCount = result.frames
      lastAnimationDurationMS = elapsedMS
      appendTraceLocked(
        "\(aborted ? "abort" : "complete") g=\(frame.generation) applied=\(result.applied) frames=\(result.frames) ms=\(String(format: "%.2f", elapsedMS))"
      )
      let successfulWindowIDs =
        successfulFinalWritesByGeneration.removeValue(
          forKey: frame.generation
        ) ?? []
      if !aborted {
        for windowID in frame.writes.keys {
          latestWriteSucceededByWindowID[windowID] =
            successfulWindowIDs.contains(windowID)
        }
        for windowID in frame.animatedWindowIDs {
          retargetHorizontalVelocities[windowID] = nil
        }
      }
      activeAnimatedSizeWindowIDs.removeAll(keepingCapacity: true)
      activeAnimatedWindowIDs.removeAll(keepingCapacity: true)
      activeWindowIDs.removeAll(keepingCapacity: true)
      activeWrites.removeAll(keepingCapacity: true)
      lock.unlock()
      frame.completion?(
        FrameWriteCompletion(
          completedLatest: !aborted,
          attemptedWindowIDs: Set(frame.writes.keys),
          successfulWindowIDs: successfulWindowIDs
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
      guard !write.isReentering else { continue }
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
        animatesSize: write.animatesSize,
        synchronousSizeWriteSucceeded: write.synchronousSizeWriteSucceeded,
        enhancedUIWasEnabled: write.enhancedUIWasEnabled,
        timeoutSeconds: write.timeoutSeconds,
        isParked: write.isParked,
        isReentering: write.isReentering,
        requiresVerifiedOffscreenWrite: write.requiresVerifiedOffscreenWrite
      )
      count += 1
    }
    let velocityCandidates: [Double] = frame.animatedWindowIDs.compactMap {
      windowID in
      guard let write = writes[windowID],
        let previousVelocity = retargetHorizontalVelocities[windowID]
      else { return nil }
      let delta = write.point.x - write.fromPoint.x
      guard abs(delta) >= 0.5 else { return nil }
      return previousVelocity / delta
    }
    let initialProgressVelocity = retainedSpringProgressVelocity(
      normalizedCandidates: velocityCandidates,
      maximum: 6 / max(frame.animationDuration, 0.04)
    )
    for windowID in frame.animatedWindowIDs {
      retargetHorizontalVelocities[windowID] = nil
    }
    guard count > 0 || initialProgressVelocity > 0 else { return (frame, 0) }
    if initialProgressVelocity > 0 {
      let velocityText = String(format: "%.2f", initialProgressVelocity)
      appendTraceLocked(
        "retarget-velocity g=\(frame.generation) v=\(velocityText)"
      )
    }
    return (
      QueuedPositionFrame(
        generation: frame.generation,
        source: frame.source,
        writes: writes,
        animatedWindowIDs: frame.animatedWindowIDs,
        animationDuration: frame.animationDuration,
        refreshRateHz: frame.refreshRateHz,
        displayID: frame.displayID,
        initialProgressVelocity: initialProgressVelocity,
        stagesVisibleBeforeParking: frame.stagesVisibleBeforeParking,
        completion: frame.completion,
        cursorWarpAfterWindowCommit: frame.cursorWarpAfterWindowCommit
      ),
      count
    )
  }
}
