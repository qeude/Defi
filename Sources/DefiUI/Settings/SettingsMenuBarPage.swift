import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct MenuBarSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    let menuBar = model.config.menuBar
    Form {
      Section {
        SettingsMenuBarPreview(config: model.config, displayCount: model.displays.count)
        Toggle(
          SettingsOption.menuBar.title,
          isOn: Binding(
            get: { model.config.menuBar.enabled },
            set: { model.set(table: "menu_bar", key: "enabled", value: $0 ? "true" : "false") }
          ))
          .settingsSearchTarget(.menuBar)
        if menuBar.enabled || request.reveals(.workspaceDisplay, .menuBarIndicator, .menuBarInactiveStyle,
          .menuBarEqualWidth, .menuBarDisplays) {
          Picker(SettingsOption.workspaceDisplay.title, selection: Binding(
            get: { model.config.menuBar.workspaceStyle },
            set: { model.set(table: "menu_bar", key: "workspace_style", value: tomlString($0.rawValue)) }
          )) {
            Text("Name only").tag(WorkspaceLabelStyle.name)
            Text("Icon only").tag(WorkspaceLabelStyle.icon)
            Text("Icon and name").tag(WorkspaceLabelStyle.iconAndName)
            Text("Number").tag(WorkspaceLabelStyle.number)
            Text("None").tag(WorkspaceLabelStyle.none)
          }
          .settingsSearchTarget(.workspaceDisplay)
          Picker(SettingsOption.menuBarIndicator.title, selection: Binding(
            get: { model.config.menuBar.indicator },
            set: { model.set(table: "menu_bar", key: "indicator", value: tomlString($0.rawValue)) }
          )) {
            Text("Dots").tag(MenuBarIndicator.dot)
            Text("Pills").tag(MenuBarIndicator.pill)
            Text("Boxes").tag(MenuBarIndicator.box)
            Text("Circles").tag(MenuBarIndicator.circle)
          }
          .settingsSearchTarget(.menuBarIndicator)
          Picker(SettingsOption.menuBarInactiveStyle.title, selection: Binding(
            get: { model.config.menuBar.inactiveStyle },
            set: { model.set(table: "menu_bar", key: "inactive_style", value: tomlString($0.rawValue)) }
          )) {
            Text("Filled").tag(MenuBarInactiveStyle.filled)
            Text("Outlined").tag(MenuBarInactiveStyle.outlined)
          }
          .settingsSearchTarget(.menuBarInactiveStyle)
          Toggle(
            SettingsOption.menuBarEqualWidth.title,
            isOn: Binding(
              get: { model.config.menuBar.equalWidth },
              set: { model.set(table: "menu_bar", key: "equal_width", value: $0 ? "true" : "false") }
            ))
            .settingsSearchTarget(.menuBarEqualWidth)
          Picker(SettingsOption.menuBarDisplays.title, selection: Binding(
            get: { model.config.menuBar.show },
            set: { model.set(table: "menu_bar", key: "show", value: tomlString($0.rawValue)) }
          )) {
            Text("All displays").tag(MenuBarDisplays.all)
            Text("Focused display").tag(MenuBarDisplays.current)
            Text("Active workspace").tag(MenuBarDisplays.active)
          }
          .settingsSearchTarget(.menuBarDisplays)
        }
        Toggle(
          SettingsOption.menuBarColumns.title,
          isOn: Binding(
            get: { model.config.menuBar.columns },
            set: { model.set(table: "menu_bar", key: "columns", value: $0 ? "true" : "false") }
          ))
          .settingsSearchTarget(.menuBarColumns)
        if menuBar.columns || request.reveals(.menuBarColumnsWidth) {
          SettingsNumberRow(
            title: SettingsOption.menuBarColumnsWidth.title, value: menuBar.columnsWidth,
            range: 30...300, step: 10, unit: "pt",
            onChange: { model.set(table: "menu_bar", key: "columns_width", value: String($0)) }
          )
            .settingsSearchTarget(.menuBarColumnsWidth)
        }
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: menuBar.enabled)
    .animation(.smooth(duration: 0.3), value: menuBar.columns)
    .modifier(SettingsRevealModifier(request: request))
  }
}
