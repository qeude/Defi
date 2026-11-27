import AppKit
import SwiftUI
import DefiMacOS

/// Grouped settings drawn as light cards over the window's glass: the system grouped style
/// shades its sections darker than the background, and no modifier changes that fill.
struct SettingsCardFormStyle: FormStyle {
  /// Builds only the cards and rows on screen, for content replaced too often to build whole, such as
  /// search results. Scrolling then builds rows, and search can scroll only to cards.
  var lazy = false

  func makeBody(configuration: Configuration) -> some View {
    ScrollView {
      Group {
        if lazy {
          LazyVStack(alignment: .leading, spacing: 18) { cards(configuration) }
        } else {
          VStack(alignment: .leading, spacing: 18) { cards(configuration) }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .labeledContentStyle(SettingsRowLabeledContentStyle())
    .toggleStyle(SettingsRowToggleStyle())
  }

  private func cards(_ configuration: Configuration) -> some View {
    ForEach(sections: configuration.content) { section in
      SettingsCard(section: section, lazy: lazy)
    }
  }
}

extension FormStyle where Self == SettingsCardFormStyle {
  static var settingsCards: SettingsCardFormStyle { SettingsCardFormStyle() }
  static func settingsCards(lazy: Bool) -> SettingsCardFormStyle { SettingsCardFormStyle(lazy: lazy) }
}

private struct SettingsCard: View {
  let section: SectionConfiguration
  let lazy: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // A mask renders offscreen while scrolling; only a card with an edge-to-edge row needs it.
      if hasEdgeToEdgeRow {
        rows
          .background(SettingsCardBackground())
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      } else {
        rows.background(SettingsCardBackground())
      }
      if !section.footer.isEmpty {
        section.footer
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)
      }
    }
  }

  private var hasEdgeToEdgeRow: Bool {
    section.content.contains { $0.containerValues.isSettingsEdgeToEdge }
  }

  @ViewBuilder private var rows: some View {
    if lazy && section.content.count > 24 {
      LazyVStack(alignment: .leading, spacing: 0) { cardRows }
    } else {
      VStack(alignment: .leading, spacing: 0) { cardRows }
    }
  }

  @ViewBuilder private var cardRows: some View {
    if !section.header.isEmpty {
      section.header
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .textCase(nil)
        .modifier(SettingsRowFrame())
      if !section.content.isEmpty { Divider().padding(.leading, 12) }
    }
    ForEach(subviews: section.content) { row in
      if row.containerValues.isSettingsEdgeToEdge {
        row
      } else if row.containerValues.isSettingsNote {
        row
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.top, -4)
          .padding(.bottom, 8)
      } else {
        if row.id != section.content.first?.id {
          Divider().padding(.leading, 12)
        }
        row.modifier(SettingsRowFrame())
      }
    }
  }
}

extension ContainerValues {
  @Entry var isSettingsNote = false
  @Entry var isSettingsEdgeToEdge = false
}

extension View {
  /// A short explanation drawn under the row above it, inside the same card.
  func settingsNote() -> some View {
    font(.caption)
      .foregroundStyle(.secondary)
      .containerValue(\.isSettingsNote, true)
  }
}

extension View {
  /// A row that fills its card to the edges, such as a preview.
  func settingsEdgeToEdge() -> some View {
    containerValue(\.isSettingsEdgeToEdge, true)
  }
}

private struct SettingsRowFrame: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
  }
}

/// A card's title row: a colored icon beside the title, as the first row of the card.
struct SettingsSectionTitle: View {
  let title: String
  let symbol: String
  let color: Color
  var info: String?

  init(_ title: String, symbol: String, color: Color, info: String? = nil) {
    self.title = title
    self.symbol = symbol
    self.color = color
    self.info = info
  }

  var body: some View {
    Label {
      if let info { SettingsInfoLabel(title, info) } else { Text(title) }
    } icon: {
      SettingsIcon(symbol: symbol, color: color, size: 24)
    }
    .labelStyle(SettingsTitleLabelStyle())
    .accessibilityAddTraits(.isHeader)
  }
}

private struct SettingsTitleLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 10) {
      configuration.icon
      configuration.title
    }
  }
}

extension Section where Parent == SettingsSectionTitle, Content: View, Footer == EmptyView {
  @MainActor init(
    _ title: String, symbol: String, color: Color, info: String? = nil, @ViewBuilder content: () -> Content
  ) {
    self.init(content: content) { SettingsSectionTitle(title, symbol: symbol, color: color, info: info) }
  }
}

struct SettingsCardBackground: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    shape
      .fill(Color.settingsCard)
      .overlay(shape.strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
  }
}

extension Color {
  static let settingsCard = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.72)
  })
}

private struct SettingsRowLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.label
      Spacer(minLength: 8)
      configuration.content
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }
}

private struct SettingsRowToggleStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 12) {
      configuration.label
      Spacer(minLength: 8)
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}
