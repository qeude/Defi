import ApplicationServices
import Foundation

/// Waits for the initial AX grant without depending on an undocumented notification.
@MainActor
public final class AccessibilityPermissionMonitor {
  static let notification = Notification.Name("com.apple.accessibility.api")
  private let center: NotificationCenter
  private let checkTrust: (Bool) -> Bool
  private var observer: NSObjectProtocol?
  private var timer: Timer?
  private var onGranted: (() -> Void)?
  private var started = false

  public init(
    center: NotificationCenter = DistributedNotificationCenter.default(),
    checkTrust: @escaping (Bool) -> Bool = { prompt in
      AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
      )
    }
  ) {
    self.center = center
    self.checkTrust = checkTrust
  }

  public func start(onGranted: @escaping () -> Void) {
    guard !started else { return }
    started = true
    self.onGranted = onGranted
    refresh()
    guard self.onGranted != nil else { return }
    // This notification is a hint only. Always confirm trust through the public API.
    observer = center.addObserver(forName: Self.notification, object: nil, queue: .main) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    _ = checkTrust(true)
    refresh()
  }

  func refresh() {
    guard let onGranted, checkTrust(false) else { return }
    stop()
    onGranted()
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    if let observer { center.removeObserver(observer) }
    observer = nil
    onGranted = nil
  }

  isolated deinit {
    timer?.invalidate()
    if let observer { center.removeObserver(observer) }
  }
}
