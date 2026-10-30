import AppKit
import Foundation
import Observation
import Security
import SwiftUI

/// The stable release certificate is the only trust root: Defi is not notarized,
/// and macOS grants its permissions to this same requirement.
let defiReleaseRequirement =
  #"identifier "com.qeude.defi" and certificate leaf = H"b81a903423676253b0eff36c4cdfbe3351742b68""#

struct AppUpdateRelease: Equatable, Sendable {
  let version: String
  let archiveURL: URL

  private struct Payload: Decodable {
    struct Asset: Decodable {
      let name: String
      let browser_download_url: URL
    }
    let tag_name: String
    let assets: [Asset]
  }

  /// Returns nil unless the payload names this repository's archive for its own tag.
  init?(json: Data) {
    guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
      payload.tag_name.hasPrefix("v")
    else { return nil }
    let version = String(payload.tag_name.dropFirst())
    guard let url = payload.assets.first(where: { $0.name == "Defi-v\(version).zip" })?
      .browser_download_url,
      url.scheme == "https", url.host() == "github.com",
      url.path().hasPrefix("/qeude/Defi/releases/download/")
    else { return nil }
    self.version = version
    archiveURL = url
  }
}

/// shortcut: numeric comparison ignores prerelease ordering, enough while updates follow
/// `releases/latest`, which only returns stable releases.
func isNewerVersion(_ candidate: String, than installed: String) -> Bool {
  candidate.compare(installed, options: .numeric) == .orderedDescending
}

enum AppUpdateError: LocalizedError {
  case unexpectedResponse
  case archiveUnreadable
  case invalidSignature
  case unexpectedVersion(String?)

  var errorDescription: String? {
    switch self {
    case .unexpectedResponse: "GitHub returned an unexpected response."
    case .archiveUnreadable: "The downloaded archive could not be read."
    case .invalidSignature: "The downloaded app is not signed by Defi's release certificate."
    case let .unexpectedVersion(version): "The downloaded app has version \(version ?? "unknown")."
    }
  }
}

/// Extracts an archive into `directory` and accepts the app only if it carries
/// the requirement and the announced version. Nothing outside `directory` changes.
func stageAppUpdate(
  archive: URL, into directory: URL, version: String, requirement: String
) throws -> URL {
  let process = Process()
  process.executableURL = URL(filePath: "/usr/bin/ditto")
  process.arguments = ["-x", "-k", archive.path, directory.path]
  try process.run()
  process.waitUntilExit()
  let app = directory.appending(path: "Defi.app")
  guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
    throw AppUpdateError.archiveUnreadable
  }

  var requirementRef: SecRequirement?
  var code: SecStaticCode?
  let flags = SecCSFlags(
    rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
  guard SecRequirementCreateWithString(requirement as CFString, [], &requirementRef) == errSecSuccess,
    SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
    let code,
    SecStaticCodeCheckValidity(code, flags, requirementRef) == errSecSuccess
  else { throw AppUpdateError.invalidSignature }

  let staged = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
  guard staged == version else { throw AppUpdateError.unexpectedVersion(staged) }
  return app
}

/// Runs detached and swaps the bundle only once the daemon has exited, so two
/// instances never coexist. A failed swap restores and reopens the installed app.
/// Arguments: daemon PID, installed app, staged app, staging directory, opener.
let appUpdateSwapScript = #"""
  while kill -0 "$1" 2>/dev/null; do
    sleep 0.2
  done
  mkdir -p "$4/previous"
  previous="$4/previous/$(basename "$2")"
  if mv "$2" "$previous"; then
    mv "$3" "$2" || mv "$previous" "$2"
  fi
  "$5" "$2"
  [ -e "$2" ] && rm -rf "$4"
  """#

@MainActor
@Observable
public final class AppUpdater {
  public static let shared = AppUpdater()

  public enum Status: Equatable {
    case idle
    case checking
    case upToDate
    case installing
    case failed(String)
  }

  public static let automaticChecksKey = "automaticallyCheckForUpdates"
  private static let latestReleaseURL = URL(string: "https://api.github.com/repos/qeude/Defi/releases/latest")!

  public internal(set) var status = Status.idle
  var release: AppUpdateRelease?
  public var availableVersion: String? { release?.version }
  /// Development builds are signed differently: they never reach the network.
  public let isEligible: Bool

  @ObservationIgnored private var quit: () -> Void = {}
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var promptedVersion: String?
  @ObservationIgnored private var panel: NSPanel?

  private var installedVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

  private init() {
    var code: SecCode?
    var requirement: SecRequirement?
    isEligible = Bundle.main.bundleURL.pathExtension == "app"
      && SecCodeCopySelf([], &code) == errSecSuccess
      && SecRequirementCreateWithString(defiReleaseRequirement as CFString, [], &requirement) == errSecSuccess
      && code.map { SecCodeCheckValidity($0, [], requirement) == errSecSuccess } == true
  }

  public func start(quit: @escaping () -> Void) {
    guard isEligible, loop == nil else { return }
    self.quit = quit
    loop = Task {
      try? await Task.sleep(for: .seconds(30))
      while !Task.isCancelled {
        if UserDefaults.standard.object(forKey: Self.automaticChecksKey) as? Bool ?? true {
          await check(manually: false)
        }
        try? await Task.sleep(for: .seconds(24 * 60 * 60))
      }
    }
  }

  public func check(manually: Bool = true) async {
    guard isEligible, status != .checking, status != .installing else { return }
    // An open panel is waiting on the user: only a manual check may replace it.
    if panel != nil {
      guard manually else { return }
      dismissPanel()
    }
    status = .checking
    do {
      var request = URLRequest(url: Self.latestReleaseURL)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let latest = AppUpdateRelease(json: data)
      else { throw AppUpdateError.unexpectedResponse }
      guard status == .checking else { return }
      let isNew = isNewerVersion(latest.version, than: installedVersion)
      release = isNew ? latest : nil
      status = !isNew && manually ? .upToDate : .idle
      // Each version prompts once per launch; the menu keeps offering it afterwards.
      // After a manual check the menu has closed: the panel is the only place to answer.
      if manually || (isNew && promptedVersion != latest.version) {
        if isNew { promptedVersion = latest.version }
        showPanel()
      }
    } catch {
      guard status == .checking else { return }
      status = manually ? .failed(error.localizedDescription) : .idle
      if manually { showPanel() }
    }
  }

  public func install() {
    guard let release, status != .installing else { return }
    status = .installing
    showPanel()
    let installed = Bundle.main.bundleURL
    let processID = ProcessInfo.processInfo.processIdentifier
    Task {
      do {
        let (archive, response) = try await URLSession.shared.download(from: release.archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw AppUpdateError.unexpectedResponse
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        try await Task.detached {
          try launchAppUpdateSwap(
            archive: archive, release: release, installed: installed, processID: processID)
        }.value
        // The swap waits for this process to exit through the normal window restoration.
        quit()
      } catch {
        status = .failed(error.localizedDescription)
      }
    }
  }

  func dismissPanel() {
    panel?.close()
    panel = nil
    switch status {
    case .upToDate, .failed: status = .idle
    default: break
    }
  }

  func openReleasePage() {
    if let url = URL(string: "https://github.com/qeude/Defi/releases/latest") {
      NSWorkspace.shared.open(url)
    }
    dismissPanel()
  }

  func showPanel() {
    guard panel == nil, let screen = NSScreen.main else { return }
    let hosting = NSHostingView(rootView: AppUpdatePanelContent(updater: self))
    // The hidden title bar reserves no space above the content.
    hosting.safeAreaRegions = []
    let size = hosting.fittingSize
    let bounds = screen.visibleFrame
    let frame = CGRect(
      x: bounds.maxX - size.width - 16, y: bounds.maxY - size.height - 16,
      width: size.width, height: size.height
    )
    // Never takes focus by appearing: a keystroke in progress must not trigger an update.
    let panel = AppUpdatePanel(
      contentRect: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
      styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: false, screen: screen
    )
    panel.title = "Defi Update"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.contentView = hosting
    self.panel = panel
    panel.orderFrontRegardless()
  }
}

private func launchAppUpdateSwap(
  archive: URL, release: AppUpdateRelease, installed: URL, processID: Int32
) throws {
  let manager = FileManager.default
  // Same volume as the app, so replacing it is a rename.
  let staging = try manager.url(
    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
  do {
    guard manager.isWritableFile(atPath: installed.deletingLastPathComponent().path),
      manager.isWritableFile(atPath: installed.path)
    else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let staged = try stageAppUpdate(
      archive: archive, into: staging, version: release.version,
      requirement: defiReleaseRequirement)
    let swap = Process()
    swap.executableURL = URL(filePath: "/bin/sh")
    swap.arguments = [
      "-c", appUpdateSwapScript, "defi-update", String(processID), installed.path, staged.path,
      staging.path, "/usr/bin/open",
    ]
    swap.standardOutput = FileHandle.nullDevice
    swap.standardError = FileHandle.nullDevice
    try swap.run()
  } catch {
    try? manager.removeItem(at: staging)
    throw error
  }
}

private final class AppUpdatePanel: NSPanel {
  override var canBecomeMain: Bool { false }
}

/// The panel never takes focus by appearing, so its first click must already press a button.
/// SwiftUI buttons drop that click while Defi is inactive; AppKit's tracks it directly.
private final class AppUpdateFirstClickButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct AppUpdateButton: NSViewRepresentable {
  let title: String
  var isPrimary = false
  let action: () -> Void

  final class Coordinator: NSObject {
    var action: () -> Void = {}
    @objc func press() { action() }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSButton {
    let button = AppUpdateFirstClickButton(
      title: title, target: context.coordinator, action: #selector(Coordinator.press))
    button.bezelStyle = .push
    if isPrimary { button.bezelColor = .controlAccentColor }
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    button.title = title
    context.coordinator.action = action
  }
}

struct AppUpdatePanelContent: View {
  let updater: AppUpdater

  private var version: String { updater.availableVersion ?? "" }

  private var title: String {
    switch updater.status {
    case .installing: "Updating Defi to \(version)…"
    case .failed: "Defi Update Failed"
    case .upToDate: "Defi Is Up to Date"
    default: "Defi \(version) Is Available"
    }
  }

  private var detail: String {
    if case let .failed(message) = updater.status { return message }
    if updater.status == .upToDate { return "You have the latest version of Defi." }
    return "Defi restarts by itself and keeps your workspaces."
  }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 56, height: 56)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
          // Every state keeps one height, so the panel never jumps under the pointer.
          .lineLimit(2, reservesSpace: true)
          .help(detail)
        Group {
          switch updater.status {
          case .installing:
            ProgressView()
              .progressViewStyle(.linear)
          case .failed:
            HStack {
              Spacer()
              AppUpdateButton(title: "Close") { updater.dismissPanel() }
                .fixedSize()
              AppUpdateButton(title: "Open Release Page", isPrimary: true) { updater.openReleasePage() }
                .fixedSize()
            }
          case .upToDate:
            HStack {
              Spacer()
              AppUpdateButton(title: "OK", isPrimary: true) { updater.dismissPanel() }
                .fixedSize()
            }
          default:
            HStack {
              Spacer()
              AppUpdateButton(title: "Later") { updater.dismissPanel() }
                .fixedSize()
              AppUpdateButton(title: "Update", isPrimary: true) { updater.install() }
                .fixedSize()
            }
          }
        }
        .frame(minHeight: 24)
        .padding(.top, 10)
      }
    }
    .padding(16)
    .frame(width: 380, alignment: .leading)
  }
}
