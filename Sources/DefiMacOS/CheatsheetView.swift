import SwiftUI

struct CheatsheetView: View {
  let groups: [ShortcutGroup]
  let size: CGSize
  let contentSizeChanged: (CGSize) -> Void
  @State private var contentSize: CGSize?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      HStack(alignment: .top, spacing: 44) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, groups in
          column(groups)
        }
      }
      .fixedSize(horizontal: true, vertical: true)
      .padding(28)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
        contentSize = measured
        contentSizeChanged(measured)
      }
    }
    .scrollIndicators(.hidden)
    .scrollDisabled(contentSize.map { $0.width <= size.width && $0.height <= size.height } ?? true)
    .frame(
      width: min(contentSize?.width ?? size.width, size.width),
      height: min(contentSize?.height ?? size.height, size.height)
    )
    // Solid at the top for legibility, then fading down into the glass.
    .background(
      LinearGradient(
        stops: [
          .init(color: core.opacity(0.94), location: 0),
          .init(color: core.opacity(0.94), location: 0.4),
          .init(color: core.opacity(0), location: 1),
        ],
        startPoint: .top, endPoint: .bottom
      ),
      in: .rect(cornerRadius: 20)
    )
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }

  private var core: Color { colorScheme == .dark ? .black : .white }

  /// Sections fill columns in reading order, balanced by row count.
  private var columns: [[ShortcutGroup]] {
    let count = size.width >= 2000 ? 3 : size.width >= 1250 ? 2 : 1
    let weight = { (group: ShortcutGroup) in group.rows.count + 2 }
    let target = Double(groups.map(weight).reduce(0, +)) / Double(count)
    var columns: [[ShortcutGroup]] = [[]]
    var filled = 0
    for group in groups {
      if !columns[columns.count - 1].isEmpty, columns.count < count,
        Double(filled) + Double(weight(group)) / 2 > target * Double(columns.count) {
        columns.append([])
      }
      columns[columns.count - 1].append(group)
      filled += weight(group)
    }
    return columns
  }

  private func column(_ groups: [ShortcutGroup]) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      ForEach(groups, id: \.title) { group in
        VStack(alignment: .leading, spacing: 10) {
          Text(group.title)
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(group.rows, id: \.self) { row in
              GridRow {
                // A shared minimum keeps labels aligned across ordinary sections.
                Chord(modifiers: row.modifiers, key: row.key)
                Text(row.action).fixedSize()
                if let shifted = row.shifted {
                  Chord(modifiers: shifted.modifiers, key: row.key)
                    .padding(.leading, 12)
                  Text(shifted.action).fixedSize()
                }
              }
              .accessibilityElement(children: .combine)
            }
          }
        }
      }
    }
    .font(.system(size: 15))
    .fixedSize()
  }
}

private struct Chord: View {
  let modifiers: String
  let key: String

  var body: some View {
    HStack(spacing: 4) {
      if !modifiers.isEmpty { KeyCap(label: modifiers) }
      KeyCap(label: key)
    }
  }
}

private struct KeyCap: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 14, weight: .semibold))
      .padding(.horizontal, 7)
      .frame(minWidth: 26, minHeight: 26)
      .background(.quaternary, in: .rect(cornerRadius: 6))
      .fixedSize()
      .accessibilityLabel(label.replacingOccurrences(of: "✧", with: "Hyper "))
  }
}
