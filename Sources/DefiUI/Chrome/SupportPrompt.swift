import AppKit
import Foundation
import SwiftUI

/// Asks for a sponsorship or a star after Defi updates to a new major version.
@MainActor
public enum SupportPrompt {
  public static let afterUpdatesKey = "askForSupportAfterUpdates"
  static let lastVersionKey = "lastLaunchedVersion"
  private static var panel: NSPanel?

  /// Never on the first launch, a minor or patch update, or a downgrade.
  nonisolated static func isMajorUpdate(from previous: String?, to current: String) -> Bool {
    guard let previous else { return false }
    func major(_ version: String) -> String { String(version.prefix { $0 != "." }) }
    return isNewerVersion(major(current), than: major(previous))
  }

  /// Release builds only, so tests and development builds never show it.
  public static func showAfterUpdate() {
    guard AppUpdater.shared.isEligible,
      let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    else { return }
    let defaults = UserDefaults.standard
    let previous = defaults.string(forKey: lastVersionKey)
    defaults.set(current, forKey: lastVersionKey)
    guard isMajorUpdate(from: previous, to: current),
      defaults.object(forKey: afterUpdatesKey) as? Bool ?? true
    else { return }
    Task {
      // After the restored workspaces have settled.
      try? await Task.sleep(for: .seconds(5))
      show()
    }
  }

  /// Also opened from the menu bar, so supporting Defi never depends on an update.
  public static func show() {
    guard panel == nil else { return }
    panel = presentFloatingPanel(title: "Support Defi", glass: true, content: SupportPromptContent())
  }

  static func open(_ url: URL) {
    NSWorkspace.shared.open(url)
    dismiss()
  }

  static func dismiss() {
    panel?.close()
    panel = nil
  }
}

let defiRepositoryURL = URL(string: "https://github.com/qeude/Defi")!

/// The light of the landing page, in the blues of the app icon.
private extension Color {
  static let defiAccent = Color(red: 0x2b / 255, green: 0x6d / 255, blue: 0xf2 / 255)
  static let defiLight = Color(red: 0x54 / 255, green: 0xaf / 255, blue: 0xff / 255)
}

struct SupportPromptContent: View {
  @AppStorage(SupportPrompt.afterUpdatesKey) private var afterUpdates = true

  var body: some View {
    VStack(spacing: 0) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 72, height: 72)
        .accessibilityHidden(true)
        .padding(.top, 24)
        .padding(.bottom, 8)
      VStack(spacing: 8) {
        Text("Support Defi")
          .font(.title3.weight(.semibold))
        Text("Defi is free and open source, built in my spare time. If you enjoy it, a star or a sponsorship is a nice way to say thanks.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 24)
      VStack(spacing: 8) {
        // A full-width label makes the capsule fill the panel.
        Button { SupportPrompt.open(defiSponsorsURL) } label: {
          Label("Sponsor…", systemImage: "heart.fill").frame(maxWidth: .infinity)
        }
          .supportPromptStyle(prominent: true)
          .keyboardShortcut(.defaultAction)
        Button { SupportPrompt.open(defiRepositoryURL) } label: {
          Label("Star on GitHub…", systemImage: "star").frame(maxWidth: .infinity)
        }
          .supportPromptStyle(prominent: false)
        Button { SupportPrompt.dismiss() } label: { Text("Not Now").frame(maxWidth: .infinity) }
          .supportPromptStyle(prominent: false)
          .keyboardShortcut(.cancelAction)
        // The suppression checkbox of a macOS alert; Settings › General has the same switch.
        Toggle("Don't show after updates", isOn: Binding(get: { !afterUpdates }, set: { afterUpdates = !$0 }))
          .toggleStyle(.checkbox)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.top, 8)
      }
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 16)
    }
    .frame(width: 344)
    .background(alignment: .bottom) { SupportPromptLight().frame(height: 200) }
    // A borderless panel has no title bar to drag; everything but the buttons moves it.
    .background { Color.clear.contentShape(.rect).gesture(WindowDragGesture()) }
    .clipShape(.rect(cornerRadius: 20, style: .continuous))
    .defiPanelSurface()
  }
}

/// Defi's columns as light rising behind the actions, as at the bottom of the landing page:
/// preset widths, 8 pt gaps, the focused one brighter. They rise once as the panel opens.
private struct SupportPromptLight: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rise: CGFloat = 1
  private let widths: [CGFloat] = [64, 40, 64, 104, 64, 40, 64]

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      ForEach(widths.indices, id: \.self) { index in
        let focused = index == 3
        UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.defiLight.opacity(focused ? 0.9 : 0.5), .defiAccent.opacity(focused ? 0.4 : 0.2), .clear],
              startPoint: .bottom, endPoint: .top)
          )
          .frame(width: widths[index])
      }
    }
    .blur(radius: 12)
    .frame(width: 344)
    .offset(y: rise * 64)
    .opacity(1 - rise)
    .mask(
      LinearGradient(
        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.6)],
        startPoint: .top, endPoint: .bottom))
    .onAppear {
      if reduceMotion { rise = 0 } else { withAnimation(.easeOut(duration: 0.25)) { rise = 0 } }
    }
    .accessibilityHidden(true)
  }
}

private extension View {
  /// Full-width capsules, in Liquid Glass where the system has it.
  @ViewBuilder func supportPromptStyle(prominent: Bool) -> some View {
    let sized = controlSize(.large)
      .buttonBorderShape(.capsule)
    if #available(macOS 26, *) {
      if prominent { sized.buttonStyle(.glassProminent) } else { sized.buttonStyle(.glass) }
    } else {
      if prominent { sized.buttonStyle(.borderedProminent) } else { sized.buttonStyle(.bordered) }
    }
  }
}
