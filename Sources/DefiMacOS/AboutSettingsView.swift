import AppKit
import SwiftUI

@MainActor
struct AboutSettingsView: View {
  let request: SettingsRevealRequest

  var body: some View {
    Form {
      Section {
        AboutSettingsHeader()
          .id(SettingsSearchAnchor.option(.about))
      }
      if AppUpdater.shared.isEligible {
        AboutUpdatesSection(updater: AppUpdater.shared)
      }
      Section("Links") {
        AboutSettingsLink(
          title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
          detail: "qeude/Defi", path: "")
        AboutSettingsLink(
          title: "Documentation", symbol: "book", detail: "Configuration guide",
          path: "/blob/main/CONFIGURATION.md")
        AboutSettingsLink(
          title: "Release Notes", symbol: "shippingbox", detail: "Latest releases",
          path: "/releases")
        AboutSettingsLink(
          title: "Report an Issue", symbol: "ladybug", detail: "Bugs and feature requests",
          path: "/issues")
      }
      Section {
        Label("Free and open source.", systemImage: "heart")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsRevealModifier(request: request))
  }
}

@MainActor
struct AboutUpdatesSection: View {
  let updater: AppUpdater
  @AppStorage(AppUpdater.automaticChecksKey) private var automaticChecks = true

  private var statusText: String {
    switch updater.status {
    case .checking: "Checking…"
    case .upToDate: "Defi is up to date."
    case .installing: "Updating…"
    case let .failed(message): message
    case .idle: updater.availableVersion.map { "Defi \($0) is available." } ?? ""
    }
  }

  var body: some View {
    Section("Updates") {
      Toggle("Automatically check for updates", isOn: $automaticChecks)
      HStack(spacing: 12) {
        Text(statusText)
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        if updater.availableVersion != nil {
          Button("Update") { updater.install() }
            .disabled(updater.status == .installing)
        } else {
          Button("Check for Updates") { Task { await updater.check() } }
            .disabled(updater.status == .checking)
        }
      }
    }
  }
}

@MainActor
private struct AboutSettingsHeader: View {
  private var version: String {
    guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
      return "Development build"
    }
    if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
      return "Version \(version) (\(build))"
    }
    return "Version \(version)"
  }

  var body: some View {
    VStack(spacing: 12) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .accessibilityHidden(true)
      Text("Defi")
        .font(.largeTitle.bold())
      Text(version)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .textSelection(.enabled)
      Text("A native macOS window manager with scrolling columns.")
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 8)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}

private struct AboutSettingsLink: View {
  let title: LocalizedStringKey
  let symbol: String
  let detail: LocalizedStringKey
  let path: String

  var body: some View {
    if let url = URL(string: "https://github.com/qeude/Defi" + path) {
      Link(destination: url) {
        HStack(spacing: 12) {
          Image(systemName: symbol)
            .frame(width: 20)
          Text(title)
          Spacer(minLength: 12)
          Text(detail)
            .foregroundStyle(.secondary)
          Image(systemName: "arrow.up.right")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(url.absoluteString)
    }
  }
}
