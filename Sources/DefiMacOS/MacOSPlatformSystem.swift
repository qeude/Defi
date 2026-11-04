import AppKit
import DefiConfig
import DefiModel
import DefiRuntime

/// The macOS reads a platform takes outside Accessibility focus and frame writes, which have
/// their own injectable writers. Production uses the real system; a simulated macOS replaces
/// these so the real daemon and platform code run against it.
public struct MacOSPlatformSystem: Sendable {
  public typealias SnapshotSource = @NavigationActor @Sendable (
    _ config: Config,
    _ completion: @escaping @NavigationActor @Sendable (DesktopSnapshot) -> Void
  ) -> Void

  /// Replaces the Accessibility and WindowServer desktop snapshot; nil reads the real desktop.
  var snapshotSource: SnapshotSource?
  /// The process macOS shows as frontmost; nil reads NSWorkspace.
  var frontmostProcessID: (@Sendable () -> pid_t?)?

  public static let real = MacOSPlatformSystem()

  init(snapshotSource: SnapshotSource? = nil, frontmostProcessID: (@Sendable () -> pid_t?)? = nil) {
    self.snapshotSource = snapshotSource
    self.frontmostProcessID = frontmostProcessID
  }
}
