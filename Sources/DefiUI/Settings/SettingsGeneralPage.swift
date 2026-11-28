import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct GeneralSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    Form {
      Section("Permissions", symbol: "lock.shield", color: .green) {
        HStack(spacing: 10) {
          PermissionTile(
            title: SettingsOption.accessibility.title, symbol: "accessibility", purpose: "Moves and focuses windows",
            granted: model.accessibilityGranted, grant: model.openAccessibilitySettings)
            .settingsSearchTarget(.accessibility)
          PermissionTile(
            title: SettingsOption.screenRecording.title, symbol: "record.circle", purpose: "Animations and previews",
            granted: model.screenCaptureAvailable, grant: model.openScreenRecordingSettings)
            .settingsSearchTarget(.screenRecording)
        }
      }
      Section("Startup", symbol: "power", color: .green) {
        Toggle(
          SettingsOption.launchAtLogin.title,
          isOn: Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLogin($0) }
          ))
          .settingsSearchTarget(.launchAtLogin)
        if let notice = model.launchAtLoginNotice {
          Text(notice)
            .settingsNote()
        }
        AutomaticUpdatesToggle()
          .settingsSearchTarget(.automaticUpdates)
        SupportPromptToggle()
          .settingsSearchTarget(.supportPrompt)
      }
      Section("Configuration", symbol: "doc.text", color: .blue) {
        HStack(spacing: 10) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: model.configurationPath))
            .resizable()
            .frame(width: 32, height: 32)
          VStack(alignment: .leading, spacing: 1) {
            Text(URL(filePath: model.configurationPath).lastPathComponent).fontWeight(.medium)
            Text((model.configurationPath as NSString).abbreviatingWithTildeInPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          Spacer(minLength: 8)
          Button("Open") { model.openConfiguration() }
            .help(SettingsOption.configurationFile.title)
            .settingsSearchTarget(.configurationFile)
          Button("Guide") { model.openDocumentation() }
            .help(SettingsOption.configurationGuide.title)
            .settingsSearchTarget(.configurationGuide)
        }
      }
      Section("Diagnostics", symbol: "stethoscope", color: .red) {
        HStack(spacing: 8) {
          Button { model.openLogs() } label: { Label("Logs", systemImage: "folder") }
            .help(SettingsOption.logs.title)
            .settingsSearchTarget(.logs)
          TriageButton()
          Spacer(minLength: 0)
        }
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(request: request))
  }
}

@MainActor
struct AutomaticUpdatesToggle: View {
  @AppStorage(AppUpdater.automaticChecksKey) private var automaticChecks = true

  var body: some View {
    if AppUpdater.shared.isEligible {
      Toggle(SettingsOption.automaticUpdates.title, isOn: $automaticChecks)
    }
  }
}

@MainActor
struct SupportPromptToggle: View {
  @AppStorage(SupportPrompt.afterUpdatesKey) private var afterUpdates = true

  var body: some View {
    if AppUpdater.shared.isEligible {
      Toggle(SettingsOption.supportPrompt.title, isOn: $afterUpdates)
    }
  }
}

@MainActor
struct TriageButton: View {
  @State private var failure: String?

  private var cliURL: URL? {
    Bundle.main.executableURL?.deletingLastPathComponent().appending(path: "defi")
  }

  var body: some View {
    if let cliURL, FileManager.default.isExecutableFile(atPath: cliURL.path) {
      HStack(spacing: 6) {
        Button {
          do {
            let launcher = try writeTriageLauncher(
              cli: cliURL, directory: FileManager.default.temporaryDirectory)
            if NSWorkspace.shared.open(launcher) {
              failure = nil
            } else {
              try? FileManager.default.removeItem(at: launcher)
              failure = "Could not open a terminal. Run defi triage from one instead."
            }
          } catch {
            failure = "Could not start triage: \(error.localizedDescription)"
          }
        } label: {
          Label("Start Triage", systemImage: "sparkle.magnifyingglass")
        }
        SettingsInfoLabel("", failure ?? "Your own coding agent investigates a problem in Terminal and drafts an issue. It asks before it fixes or posts anything.")
        if let failure {
          Text(failure).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
      }
    }
  }
}

/// One permission at a glance: what it is for, and a check or a way to grant it.
struct PermissionTile: View {
  let title: String
  let symbol: String
  let purpose: String
  let granted: Bool
  let grant: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(granted ? Color.green : .orange)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).fontWeight(.medium)
        Text(purpose).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      if granted {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.green)
          .accessibilityLabel("Granted")
      } else {
        Button("Grant…", action: grant)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

/// Opening a `.command` file runs it in the user's terminal, with their login PATH, and needs no
/// Automation permission.
func writeTriageLauncher(cli: URL, directory: URL) throws -> URL {
  let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  let url = directory.appending(path: "defi-triage-\(UUID().uuidString).command")
  try "#!/bin/sh\nrm -f \"$0\"\nexec \(quoted) triage\n".write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  return url
}

/// A rule's display as Settings shows it, marked when no connected display matches.
