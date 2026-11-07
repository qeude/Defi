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
      Section("Links") {
        AboutSettingsLink(
          title: "Website", symbol: "globe", detail: "qeude.github.io/Defi",
          url: "https://qeude.github.io/Defi/")
        AboutSettingsLink(
          title: "Documentation", symbol: "book", detail: "Configuration guide",
          url: "https://github.com/qeude/Defi/blob/main/CONFIGURATION.md")
        AboutSettingsLink(
          title: "Release Notes", symbol: "shippingbox", detail: "Latest releases",
          url: "https://github.com/qeude/Defi/releases")
        AboutSettingsLink(
          title: "GitHub", logo: .github,
          detail: "qeude/Defi", url: "https://github.com/qeude/Defi")
        AboutSettingsLink(
          title: "Report an Issue", symbol: "ladybug", detail: "Bugs and feature requests",
          url: "https://github.com/qeude/Defi/issues")
        AboutSettingsLink(
          title: "X", logo: .x, detail: "@q_eude", url: "https://x.com/q_eude")
      }
      Section {
        HStack(spacing: 12) {
          Image(systemName: "heart.fill")
            .font(.title2)
            .foregroundStyle(.pink)
            .frame(width: 40, height: 40)
            .background(.pink.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 2) {
            Text("Support")
              .font(.headline)
            Text("Defi is free and built in my spare time. A coffee keeps it going.")
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
          Link("Sponsor…", destination: defiSponsorsURL)
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .help(defiSponsorsURL.absoluteString)
        }
        .padding(.vertical, 4)
      }
    }
    .formStyle(.grouped)
    .modifier(SettingsRevealModifier(request: request))
  }
}

/// Sits under the version in the header, where people look when they wonder whether they are current.
@MainActor
private struct AboutUpdateControl: View {
  let updater: AppUpdater

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
    VStack(spacing: 6) {
      if updater.availableVersion != nil {
        Button("Update") { updater.install() }
          .disabled(updater.status == .installing)
      } else {
        Button("Check for Updates") { Task { await updater.check() } }
          .disabled(updater.status == .checking)
      }
      if !statusText.isEmpty {
        Text(statusText)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
  }
}

let defiSponsorsURL = URL(string: "https://github.com/sponsors/qeude")!

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
      if AppUpdater.shared.isEligible {
        AboutUpdateControl(updater: AppUpdater.shared)
      }
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
  var symbol = ""
  var logo: NSImage?
  let detail: LocalizedStringKey
  let url: String

  var body: some View {
    if let url = URL(string: url) {
      Link(destination: url) {
        HStack(spacing: 12) {
          Group {
            if let logo {
              Image(nsImage: logo).resizable().scaledToFit().frame(width: 15, height: 15)
            } else {
              Image(systemName: symbol)
            }
          }
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

extension NSImage {
  /// Brand marks have no SF Symbol; template rendering tints them like the symbols beside them.
  fileprivate static let github = brandMark(##"<svg viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" fill="none"><path fill="#1b1f23" fill-rule="evenodd" d="M512 0C229.12 0 0 229.12 0 512c0 226.56 146.56 417.92 350.08 485.76 25.6 4.48 35.2-10.88 35.2-24.32 0-12.16-.64-52.48-.64-95.36-128.64 23.68-161.92-31.36-172.16-60.16-5.76-14.72-30.72-60.16-52.48-72.32-17.92-9.6-43.52-33.28-.64-33.92 40.32-.64 69.12 37.12 78.72 52.48 46.08 77.44 119.68 55.68 149.12 42.24 4.48-33.28 17.92-55.68 32.64-68.48-113.92-12.8-232.96-56.96-232.96-252.8 0-55.68 19.84-101.76 52.48-137.6-5.12-12.8-23.04-65.28 5.12-135.68 0 0 42.88-13.44 140.8 52.48 40.96-11.52 84.48-17.28 128-17.28s87.04 5.76 128 17.28c97.92-66.56 140.8-52.48 140.8-52.48 28.16 70.4 10.24 122.88 5.12 135.68 32.64 35.84 52.48 81.28 52.48 137.6 0 196.48-119.68 240-233.6 252.8 18.56 16 34.56 46.72 34.56 94.72 0 68.48-.64 123.52-.64 140.8 0 13.44 9.6 29.44 35.2 24.32C877.44 929.92 1024 737.92 1024 512 1024 229.12 794.88 0 512 0" clip-rule="evenodd"/></svg>"##)
  fileprivate static let x = brandMark(##"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1227" fill="none" viewBox="0 0 1200 1227"><path fill="#000" d="M714.163 519.284 1160.89 0h-105.86L667.137 450.887 357.328 0H0l468.492 681.821L0 1226.37h105.866l409.625-476.152 327.181 476.152H1200L714.137 519.284h.026ZM569.165 687.828l-47.468-67.894-377.686-540.24h162.604l304.797 435.991 47.468 67.894 396.2 566.721H892.476L569.165 687.854v-.026Z"/></svg>"##)

  private static func brandMark(_ svg: String) -> NSImage? {
    let image = NSImage(data: Data(svg.utf8))
    image?.isTemplate = true
    return image
  }
}
