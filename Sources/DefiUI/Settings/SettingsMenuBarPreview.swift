import AppKit
import DefiConfig
import SwiftUI
import DefiMacOS

/// A menu bar with Defi's item drawn by the same code as the real one, from the configured
/// workspaces. A change morphs the item the way the menu bar animates it.
struct SettingsMenuBarPreview: View {
  let config: Config
  let displayCount: Int
  @State private var from: MenuBarLayout?
  @State private var progress = 1.0

  var body: some View {
    let menuBar = config.menuBar
    let target = menuBarLayout(Self.sampleMonitors(config, displays: displayCount), config: menuBar)
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Image(systemName: "applelogo").font(.system(size: 14, weight: .semibold))
        Text("Finder").fontWeight(.bold)
        Text("File")
        Text("Edit")
        Text("View")
        Spacer(minLength: 12)
        if menuBar.columns {
          let columns = menuBarColumnsImage(menuBarColumnsLayout(Self.sampleMonitors(config, displays: 1).first,
            maxWidth: menuBar.columnsWidth))
          Image(nsImage: columns)
            .resizable()
            .renderingMode(.template)
            .frame(width: columns.size.width * 1.35, height: columns.size.height * 1.35)
            .transition(.scale.combined(with: .opacity))
        }
        if menuBar.enabled {
          MenuBarPreviewItem(from: from ?? target, to: target, progress: progress)
            .transition(.scale.combined(with: .opacity))
        }
        Image(systemName: "wifi")
        Image(systemName: "battery.75percent")
        Text("Thu 9:41")
      }
      .font(.system(size: 13))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(height: 30)
      .background(.black.opacity(0.28))
      // Only items appearing or leaving animate here; the workspace item morphs itself, and a layout
      // animation on top of it stretched the image between sizes.
      .animation(.smooth(duration: 0.3), value: menuBar.enabled)
      .animation(.smooth(duration: 0.3), value: menuBar.columns)
      Spacer(minLength: 0)
    }
    .settingsStage(height: 76)
    .onChange(of: target) { old, _ in
      from = from.map { interpolate($0, old, progress) } ?? old
      progress = 0
      withAnimation(.smooth(duration: 0.35)) { progress = 1 }
    }
    .accessibilityElement()
    .accessibilityLabel("Preview of the menu bar")
  }

  /// The configured named workspaces, then numbered ones, the first active and the last empty.
  static func sampleMonitors(_ config: Config, displays: Int) -> [MenuMonitor] {
    let named = config.workspaces.names.prefix(3).map { ($0, config.workspaces.icons[$0]) }
    let labels = named + (named.count + 1...max(named.count + 1, 3)).map { (String($0), nil as String?) }
    let workspaces = labels.enumerated().map { index, entry in
      MenuWorkspace(id: entry.0, label: entry.0, icon: entry.1, position: index + 1, isEmpty: index == labels.count - 1)
    }
    let columns = [MenuColumn(x: -300, width: 500, windows: 1, windowID: 1),
      MenuColumn(x: 220, width: 700, windows: 2, windowID: 2), MenuColumn(x: 940, width: 520, windows: 1, windowID: 3)]
    let main = MenuMonitor(id: 1, isFocused: true, activeWorkspace: workspaces[0].id, workspaces: workspaces,
      columns: columns, focusedColumn: 1, stripWidth: 1440)
    guard displays > 1, config.menuBar.show == .all else { return [main] }
    let second = MenuWorkspace(id: "display-2", label: "2", position: 1)
    return [main, MenuMonitor(id: 2, isFocused: false, activeWorkspace: second.id, workspaces: [second])]
  }
}

private struct MenuBarPreviewItem: View, Animatable {
  let from: MenuBarLayout
  let to: MenuBarLayout
  var progress: Double

  nonisolated var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    let image = menuBarImage(interpolate(from, to, progress))
    // Larger than the real item so it reads at a glance; the image redraws at any size.
    Image(nsImage: image)
      .resizable()
      .renderingMode(.template)
      .frame(width: image.size.width * 1.35, height: image.size.height * 1.35)
  }
}
