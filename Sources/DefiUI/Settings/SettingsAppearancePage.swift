import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct AppearanceSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @AppStorage(settingsShowAdvancedKey) private var advanced = false

  var body: some View {
    let borders = model.config.decorations.borders
    Form {
      Section {
        SettingsBorderPreview(config: model.config)
          .settingsEdgeToEdge()
      }
      Section("Window borders", symbol: "square.dashed.inset.filled", color: .purple) {
        settingsToggle(
          model, title: SettingsOption.focusedBorder.title, table: "decorations.borders",
          key: "enabled", value: borders.enabled
        )
          .settingsSearchTarget(.focusedBorder)
        if borders.enabled || request.reveals(.borderWidth, .focusedBorderColor, .borderPlacement, .captureBorders) {
          SettingsNumberRow(
            title: SettingsOption.borderWidth.title, value: borders.width,
            range: 0...64, step: 1, unit: "px",
            onChange: { model.set(table: "decorations.borders", key: "width", value: String($0)) }
          )
            .settingsSearchTarget(.borderWidth)
          ColorPicker(SettingsOption.focusedBorderColor.title, selection: colorBinding("color"), supportsOpacity: true)
            .settingsSearchTarget(.focusedBorderColor)
          Picker(SettingsOption.borderPlacement.title, selection: stringBinding(
            model, table: "decorations.borders", key: "placement", value: borders.placement
          )) {
            Text("Inside window").tag("inside")
            Text("Outside window").tag("outside")
          }
          .settingsSearchTarget(.borderPlacement)
          settingsToggle(
            model, title: SettingsOption.captureBorders.title, table: "decorations.borders",
            key: "capture_enabled", value: borders.captureEnabled
          )
            .settingsSearchTarget(.captureBorders)
        }
      }
      Section("Unfocused windows", symbol: "circle.lefthalf.filled", color: .gray) {
        SettingsNumberRow(
          title: SettingsOption.unfocusedDim.title, value: borders.inactiveDim * 100,
          range: 0...90, step: 5, unit: "%",
          onChange: { model.set(table: "decorations.borders", key: "inactive_dim", value: String($0 / 100)) }
        )
          .settingsSearchTarget(.unfocusedDim)
        settingsToggle(
          model, title: SettingsOption.unfocusedBorders.title, table: "decorations.borders",
          key: "inactive_enabled", value: borders.inactiveEnabled
        )
          .settingsSearchTarget(.unfocusedBorders)
        if borders.inactiveEnabled || request.reveals(.unfocusedBorderColor) {
          ColorPicker(SettingsOption.unfocusedBorderColor.title, selection: colorBinding("inactive_color"), supportsOpacity: true)
            .settingsSearchTarget(.unfocusedBorderColor)
        }
      }
      Section("Animation", symbol: "wand.and.stars", color: .pink) {
        settingsToggle(
          model, title: SettingsOption.animations.title, table: "animation", key: "enabled",
          value: model.config.animation.enabled
        )
          .settingsSearchTarget(.animations)
        if model.config.animation.enabled || request.reveals(.animationStiffness, .animationDamping) {
          SettingsAdvancedButton(expanded: $advanced)
          if advanced || request.reveals(.animationStiffness, .animationDamping) {
            SettingsNumberRow(
              title: SettingsOption.animationStiffness.title, value: model.config.animation.stiffness,
              range: 100...2_000, step: 50, unit: "",
              info: "Spring stiffness of every motion. Higher is faster.",
              onChange: { model.set(table: "animation", key: "stiffness", value: String($0)) }
            )
              .settingsSearchTarget(.animationStiffness)
            SettingsNumberRow(
              title: SettingsOption.animationDamping.title, value: model.config.animation.dampingRatio,
              range: 0.5...1, step: 0.05, unit: "",
              info: "1 never overshoots. Lower values arrive sooner and overshoot slightly.",
              onChange: { model.set(table: "animation", key: "damping_ratio", value: String($0)) }
            )
              .settingsSearchTarget(.animationDamping)
          }
        }
      }
      Section("Overview", symbol: "square.grid.2x2", color: .blue) {
        settingsToggle(
          model, title: SettingsOption.windowPreviews.title, table: "overview",
          key: "window_previews", value: model.config.overview.windowPreviews
        )
          .settingsSearchTarget(.windowPreviews)
        settingsToggle(
          model, title: SettingsOption.overviewSearchBar.title, table: "overview",
          key: "search_bar", value: model.config.overview.searchBar
        )
          .settingsSearchTarget(.overviewSearchBar)
        SettingsAdvancedButton(expanded: $advanced)
        if advanced || request.reveals(.overviewScale, .overviewCornerRadius) {
          SettingsNumberRow(
            title: SettingsOption.overviewScale.title, value: model.config.overview.zoom * 100,
            range: 0...75, step: 5, unit: "%",
            onChange: { model.set(table: "overview", key: "zoom", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.overviewScale)
          SettingsNumberRow(
            title: SettingsOption.overviewCornerRadius.title, value: model.config.overview.windowCornerRadius,
            range: 0...64, step: 1, unit: "px",
            onChange: { model.set(table: "overview", key: "window_corner_radius", value: String($0)) }
          )
            .settingsSearchTarget(.overviewCornerRadius)
        }
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: borders.enabled)
    .animation(.smooth(duration: 0.3), value: borders.inactiveEnabled)
    .animation(.smooth(duration: 0.3), value: model.config.animation.enabled)
    .animation(.smooth(duration: 0.3), value: advanced)
    .modifier(SettingsRevealModifier(request: request))
  }

  private func colorBinding(_ key: String) -> Binding<Color> {
    Binding(
      get: { settingsColor(key == "color" ? model.config.decorations.borders.color : model.config.decorations.borders.inactiveColor) },
      set: { model.set(table: "decorations.borders", key: key, value: tomlString(settingsHexColor($0))) }
    )
  }
}
