import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct LayoutSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @State private var editingDisplay: DisplayLayoutSheet?

  var body: some View {
    Form {
      Section("Columns", symbol: "rectangle.split.3x1", color: .teal) {
        SettingsColumnsPreview(layout: model.config.layout)
        SettingsNumberRow(
          title: SettingsOption.defaultColumnWidth.title, value: model.config.layout.defaultColumnWidth * 100,
          range: 5...100, step: 5, unit: "%",

          onChange: { model.set(table: "layout", key: "default_column_width", value: String($0 / 100)) }
        )
          .settingsSearchTarget(.defaultColumnWidth)
        Picker(
          SettingsOption.focusedColumn.title,
          selection: stringBinding(
            "layout", "center_focused_column", model.config.layout.centerFocusedColumn.rawValue)
        ) {
          Text("Reveal as needed").tag(CenterFocusedColumn.never.rawValue)
          Text("Always center").tag(CenterFocusedColumn.always.rawValue)
          Text("Center on overflow").tag(CenterFocusedColumn.onOverflow.rawValue)
        }
        .settingsSearchTarget(.focusedColumn)
        settingsToggle(
          model, title: SettingsOption.centerLoneColumn.title, table: "layout",
          key: "always_center_single_column", value: model.config.layout.alwaysCenterSingleColumn
        )
          .settingsSearchTarget(.centerLoneColumn)
      }
      PresetsSettings(
        title: "Width presets", footer: "Cycle Width switches between these sizes in list order.",
        kind: .width, values: model.config.layout.presetColumnWidths,
        centering: model.config.layout.centerFocusedColumn
      ) {
        model.set(table: "layout", key: "preset_column_widths", value: tomlArray($0))
      }
        .settingsSearchTarget(.widthPresets)
      PresetsSettings(
        title: "Height presets",
        footer: "Switch Preset Window Height gives a stacked window these shares of its column in list order.",
        kind: .height, values: model.config.layout.presetWindowHeights,
        centering: model.config.layout.centerFocusedColumn
      ) {
        model.set(table: "layout", key: "preset_window_heights", value: tomlArray($0))
      }
        .settingsSearchTarget(.heightPresets)
      DisplayLayoutsSection(model: model, editing: $editingDisplay)
        .settingsSearchTarget(.displayLayouts)
      Section("Spacing", symbol: "square.dashed", color: .mint,
        info: "Margins at each screen edge, the gap between windows, and the areas kept free at the top and bottom of the screen.") {
        SpacingEditor(model: model)
          .settingsEdgeToEdge()
          .settingsSearchTarget(.screenMargins)
      }
    }
    .formStyle(.settingsCards)
    .modifier(SettingsRevealModifier(request: request))
    .settingsSubpage(item: $editingDisplay, title: \.id) { DisplayLayoutEditor(model: model, name: $0.id) }
  }

  private func stringBinding(_ table: String, _ key: String, _ value: String) -> Binding<String> {
    Binding(get: { value }, set: { model.set(table: table, key: key, value: tomlString($0)) })
  }
}

enum PresetKind {
  case width, height

  var name: String { self == .width ? "width" : "height" }
  /// Matches the validation in DefiConfig: a stacked window never takes the whole column.
  var maximum: Double { self == .width ? 100 : 95 }

  /// Percentages the add menu offers.
  func addableChoices(to values: [Double]) -> [Int] {
    [25, 33, 50, 67, 75, 100].filter { Double($0) <= maximum && !Self.duplicates(Double($0), in: values) }
  }

  /// A duplicate preset would stop the preset cycle on its first copy.
  static func duplicates(_ percentage: Double, in values: [Double], except index: Int? = nil) -> Bool {
    values.indices.contains { $0 != index && abs(values[$0] * 100 - percentage) < 0.5 }
  }
}

@MainActor
struct PresetsSettings: View {
  let title: String
  let footer: String
  let kind: PresetKind
  let values: [Double]
  let centering: CenterFocusedColumn
  let save: ([Double]) -> Void
  @State private var hovered: Int?

  var body: some View {
    Section {
      SettingsPresetsPreview(kind: kind, values: values, held: hovered, centering: centering)
      PresetChips(kind: kind, values: values, save: save, hovered: $hovered)
    } header: {
      HStack {
        SettingsSectionTitle(title, symbol: kind == .width ? "arrow.left.and.right" : "arrow.up.and.down",
          color: kind == .width ? .blue : .indigo, info: footer)
        Spacer()
        AddPresetMenu(kind: kind, values: values, save: save)
      }
    }
  }
}

@MainActor
struct AddPresetMenu: View {
  let kind: PresetKind
  let values: [Double]
  let save: ([Double]) -> Void

  var body: some View {
    Menu {
      ForEach(kind.addableChoices(to: values), id: \.self) { percentage in
        Button("\(percentage)%") {
          save(values + [Double(percentage) / 100])
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .accessibilityLabel("Add \(kind.name) preset")
  }
}

func tomlArray(_ widths: [Double]) -> String {
  "[\(widths.map { String($0) }.joined(separator: ", "))]"
}

func percentage(_ width: Double) -> String { "\(Int((width * 100).rounded())) %" }

func percentages(_ widths: [Double]) -> String {
  widths.map { "\(Int(($0 * 100).rounded()))" }.joined(separator: ", ") + " %"
}

struct DisplayLayoutSheet: Identifiable {
  let id: String
}

/// One row per display; its widths open in a sheet so the page stays short with many displays.
@MainActor
struct DisplayLayoutsSection: View {
  let model: DefiSettingsModel
  @Binding var editing: DisplayLayoutSheet?

  var body: some View {
    Section {
      ForEach(Array(model.monitorLayoutNames.enumerated()), id: \.offset) { _, name in
        Button { editing = DisplayLayoutSheet(id: name) } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(summary(name)).font(.caption).foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.settingsNavigation)
        .accessibilityHint("Customize widths on this display")
      }
    } header: {
      SettingsSectionTitle("Displays", symbol: "display", color: .cyan,
        info: "Give a display its own column widths. Other displays use the values above.")
    }
  }

  private func summary(_ name: String) -> String {
    let connection = model.displayNames.contains(name) ? "" : "Not connected · "
    guard let override = model.monitorLayout(name) else { return connection + "Same as all displays" }
    let width = override.defaultColumnWidth.map(percentage) ?? "same width"
    let presets = override.presetColumnWidths.map { "presets \(percentages($0))" } ?? "same presets"
    return connection + "\(width) · \(presets)"
  }
}

/// Each value inherits the global one until customized; inheriting both removes the display's table.
@MainActor
struct DisplayLayoutEditor: View {
  let model: DefiSettingsModel
  let name: String
  @Environment(\.closeSettingsSubpage) private var dismiss

  var body: some View {
    let override = model.monitorLayout(name)
    let layout = model.config.layout
    Form {
        Section {
          Toggle("Same as all displays", isOn: Binding(
            get: { override?.defaultColumnWidth == nil },
            set: { model.setMonitorLayout(name, key: "default_column_width", value: $0 ? nil : String(layout.defaultColumnWidth)) }
          ))
          if let width = override?.defaultColumnWidth {
            SettingsNumberRow(
              title: "Width", value: width * 100, range: 5...100, step: 5, unit: "%",
              onChange: { model.setMonitorLayout(name, key: "default_column_width", value: String($0 / 100)) }
            )
          } else {
            LabeledContent("Width", value: percentage(layout.defaultColumnWidth))
              .foregroundStyle(.secondary)
          }
        } header: {
          SettingsInfoLabel(SettingsOption.defaultColumnWidth.title, "New windows on \(name) open at this width.")
        }
        Section {
          Toggle("Same as all displays", isOn: Binding(
            get: { override?.presetColumnWidths == nil },
            set: {
              model.setMonitorLayout(
                name, key: "preset_column_widths", value: $0 ? nil : tomlArray(layout.presetColumnWidths))
            }
          ))
          if let presets = override?.presetColumnWidths {
            let save = { model.setMonitorLayout(name, key: "preset_column_widths", value: tomlArray($0)) }
            PresetChips(kind: .width, values: presets, save: save, hovered: .constant(nil))
            LabeledContent("Add preset") { AddPresetMenu(kind: .width, values: presets, save: save) }
          } else {
            LabeledContent("Presets", value: percentages(layout.presetColumnWidths))
              .foregroundStyle(.secondary)
          }
        } header: {
          SettingsInfoLabel("Width presets", "Cycle Width steps through these on \(name). Spacing stays the same on every display.")
        }
    }
    .formStyle(.settingsCards)
    .safeAreaInset(edge: .bottom) {
      SettingsSubpageActions { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
    }
  }
}
