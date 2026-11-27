import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

struct SettingsNumberRow: View {
  let title: String
  let value: Double
  let range: ClosedRange<Double>
  let step: Double
  let unit: String
  var info: String?
  let onChange: (Double) -> Void

  private var valueBinding: Binding<Double> {
    Binding(get: { value }, set: { onChange($0) })
  }

  var body: some View {
    HStack(spacing: 8) {
      if let info { SettingsInfoLabel(title, info) } else { Text(title) }
      Spacer()
      TextField(title, value: valueBinding, format: .number.precision(.fractionLength(0...2)))
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 88)
      Text(unit).foregroundStyle(.secondary).frame(width: 25, alignment: .leading)
      Stepper(title, value: valueBinding, in: range, step: step)
        .labelsHidden()
    }
  }
}

@MainActor
func settingsToggle(
  _ model: DefiSettingsModel,
  title: String,
  table: String,
  key: String,
  value: Bool
) -> some View {
  Toggle(title, isOn: Binding(
    get: { value },
    set: { model.set(table: table, key: key, value: $0 ? "true" : "false") }
  ))
}

@MainActor
func stringBinding(
  _ model: DefiSettingsModel,
  table: String,
  key: String,
  value: String
) -> Binding<String> {
  Binding(get: { value }, set: { model.set(table: table, key: key, value: tomlString($0)) })
}

func percent(_ value: Double) -> String {
  "\(Int((value * 100).rounded()))%"
}

/// The borders default, parsed so it keeps the `#AARRGGBB` order `settingsColor` reads.
let defaultBorderColor = parseBorderColor(BordersConfig().color) ?? 0

func settingsColor(_ value: String) -> Color {
  let bits = parseBorderColor(value) ?? defaultBorderColor
  return Color(
    .sRGB,
    red: Double((bits >> 16) & 0xFF) / 255,
    green: Double((bits >> 8) & 0xFF) / 255,
    blue: Double(bits & 0xFF) / 255,
    opacity: Double((bits >> 24) & 0xFF) / 255
  )
}

func settingsHexColor(_ color: Color) -> String {
  let value = (NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor(color))
  return String(
    format: "#%02X%02X%02X%02X",
    Int((value.alphaComponent * 255).rounded()),
    Int((value.redComponent * 255).rounded()),
    Int((value.greenComponent * 255).rounded()),
    Int((value.blueComponent * 255).rounded())
  )
}

extension DynamicViewContent {
  @ViewBuilder
  func settingsReorderable() -> some View {
    #if canImport(SwiftUI, _version: 8.0)
    if #available(macOS 27, *) {
      reorderable()
    } else {
      self
    }
    #else
    self
    #endif
  }
}

struct SettingsReorderContainer<Item, ID: Hashable & Sendable>: ViewModifier {
  let itemID: KeyPath<Item, ID>
  let move: ([ID], ID?) -> Void

  @ViewBuilder
  func body(content: Content) -> some View {
    #if canImport(SwiftUI, _version: 8.0)
    if #available(macOS 27, *) {
      content.reorderContainer(for: Item.self, itemID: itemID) { difference in
        switch difference.destination.position {
        case .before(let id): move(difference.sources, id)
        case .end: move(difference.sources, nil)
        }
      }
    } else {
      content
    }
    #else
    content
    #endif
  }
}

/// Shows fine-tuning a card keeps folded by default. One preference for every card, so opening it once
/// keeps it open everywhere.
let settingsShowAdvancedKey = "DefiSettingsShowAdvanced"

struct SettingsAdvancedButton: View {
  @Binding var expanded: Bool

  var body: some View {
    Button { expanded.toggle() } label: {
      HStack {
        Text("Advanced").foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
          .rotationEffect(.degrees(expanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(expanded ? "Hide advanced settings" : "Show advanced settings")
  }
}

struct SettingsInfoLabel: View {
  let title: String
  let text: String
  let note: String?
  @State private var isPresented = false

  init(_ title: String, _ text: String, note: String? = nil) {
    self.title = title
    self.text = text
    self.note = note
  }

  var body: some View {
    HStack(spacing: 4) {
      if !title.isEmpty { Text(title) }
      Button { isPresented = true } label: { Image(systemName: "info.circle") }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(title.isEmpty ? "More information" : "About \(title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
          VStack(alignment: .leading, spacing: 8) {
            Text(text)
            if let note { Text(note).foregroundStyle(.secondary) }
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: 280, alignment: .leading)
          .padding()
        }
    }
  }
}
