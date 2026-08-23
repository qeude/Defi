# Runtime domain migration (ADR 0002) - execution plan

Status: **step A landed** (`16153ca`), steps B-C pending. Each step is one
revertable commit and must keep `swift test` green.

## Done - step A (16153ca)

All ~75 snapshot-chain fields moved from `MacOSPlatform` into
`SnapshotEngine` (`Sources/DefiMacOS/SnapshotEngine.swift`), NSLock-guarded
computed properties over a private `Storage` struct. `MacOSPlatform` exposes
transparent forwarding properties, so no call site changed. Execution still
happens entirely on the main thread (uncontended lock).

## Isolation map (verified by code audit)

- `MacOSPlatform` is `@MainActor final class` (MacOSPlatform.swift:9); every
  stored property inherits that isolation. Forwarders on the platform delegate
  to the engine's locked accessors.
- Snapshot chain = `snapshot()` (MacOSPlatform+Snapshot.swift) +
  `discoverSnapshotWindows` / `resolveTransientOwners`
  (+WindowSnapshotDiscovery.swift) + helpers they call:
  `makeWindow`, `windowDisposition`, `focusedWindowID`, `stableWindowID`,
  `frame(of:)`, `copyAttribute`, `value`, `copyElements`
  (MacOSPlatform+WindowDiscovery.swift), plus pure policy functions in
  WindowRefreshPolicy.swift / WindowDiscoverySupport.swift.
- Main-bound members referenced inside the chain (must hop via
  `engine.onMain { $0... }`): `eventMonitor?.refresh(...)`,
  `eventMonitor?.prepareForWindowDiscovery(processID:application:)`,
  `eventMonitor?.processIDsWithoutReliableFrameCoverage`,
  `incompatibleObservationProcessIDs`,
  `processIDsWithoutReliableTopologyCoverage()`, `discoverMonitors()`
  (NSScreen), `invalidatePointerHitTestCache()`,
  `recordCommandObservation(...)` (FramePerformance.swift:162),
  `windowIDProvider.windowID(for:)` inside `makeWindow`.
- Thread-safe references safe to use directly from the engine:
  `frameCoordinator`, `userInputTracker` (both injected), AX messaging via
  `AXMessagingTimeoutAccess.shared.withTimeout`, `CGEventSource.buttonState`.
- Single production call site: DaemonDesktopSynchronization.swift:19.
  Tests call `platform.snapshot(config:)` ~30 times (DesktopE2ETests) -
  keep a synchronous compatibility wrapper.
- No semaphores or group waits anywhere in the chain (only coordinator
  internals, unrelated).

## Step B - move execution into the engine

1. Add to `SnapshotEngine`:
   ```swift
   weak var host: MacOSPlatform?

   func onMain<T>(_ work: @MainActor (MacOSPlatform) -> T) -> T {
     precondition(host != nil, "host must be set")
     if Thread.isMainThread { return MainActor.assumeIsolated { work(host!) } }
     return DispatchQueue.main.sync { MainActor.assumeIsolated { work(host!) } }
   }
   ```
   Safe because nothing on main ever waits on the engine queue (step C keeps
   the daemon async toward snapshots). The `Thread.isMainThread` branch makes
   the synchronous test path deadlock-free.
2. Retarget both extension headers:
   `@MainActor extension MacOSPlatform {` -> `extension SnapshotEngine {` in
   MacOSPlatform+Snapshot.swift and MacOSPlatform+WindowSnapshotDiscovery.swift.
3. Move the eight helper functions listed above out of
   MacOSPlatform+WindowDiscovery.swift into the engine file. Do this
   **manually, one function at a time** (brace-matching scripts mis-fired;
   each function ends at the first `\n  }` at two-space indent).
4. Wrap every main-bound member from the map with `onMain { $0.... }`
   (exact site list above). `NSWorkspace.runningApplications`,
   `NSRunningApplication(processIdentifier:)` and `CGEventSource.buttonState`
   are used directly (thread-safe).
5. Platform keeps and stays @MainActor: `prepareAXWindowAttributesIfNeeded`
   (+invalidate), `discoverMonitors()`, prefetch APIs, everything outside the
   chain. They talk to engine state through the existing forwarders.
6. Compatibility wrapper on the platform (tests + daemon keep compiling,
   still synchronous-on-main):
   ```swift
   public func snapshot(config: Config, forceFullWindowRefresh: Bool = false,
       forceWindowListRefresh: Bool = false,
       forceApplicationInventoryRefresh: Bool = false) -> DesktopSnapshot {
     snapshotEngine.host = self
     return snapshotEngine.snapshot(config: config, ...)
   }
   ```
7. Known pitfalls from the attempted pass (all fixed by manual edits):
   duplicate `private var storage` after scripted insertions; `Storage.init`
   needs a default argument (`= AXFrameCoordinator()`); successive scripted
   rewrites drift anchors - edit functions by hand.

## Step C - flip the daemon to the async pipeline

1. Engine gains `private let queue = DispatchQueue(label:
   "com.quentin.defi.snapshot", qos: .userInitiated)` and an async entry:
   schedule `snapshot(...)` on it, hop the returned `DesktopSnapshot` back to
   main through the completion.
2. Split `Daemon.synchronizeDesktop` at its seam (line 25, right after the
   snapshot returns): request phase clears `needsDesktopSync`, guards with an
   in-flight generation (latest-wins: a newer request supersedes an in-flight
   one and reruns once); apply phase receives the snapshot and runs the rest
   of today's body unchanged.
3. The budget/chunking machinery added in `a2c84b3`/`f5c6aa2` becomes optional
   once main never blocks on reads; evaluate removing
   `budgetedFreshReadPartition` usage (keep the incompatible-app watchdog
   cadence - those reads stay expensive).

## Verification per step

`swift build && swift test`; then `./script/build_and_run.sh --verify`;
Computer Use pass on resize/navigation; confirm exactly one defi-daemon;
compare `inputPlanN` percentiles and `queueWaitMS` in the diagnostics journal
against the pre-step baseline (P50 0.6 ms / burst max 0 ms post-a2c84b3).
