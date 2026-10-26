import SwiftUI

struct CheatsheetView: View {
  let groups: [ShortcutGroup]
  let layout: CheatsheetLayout
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      CheatsheetContent(groups: groups, columnCount: layout.columns)
        .scaleEffect(layout.scale, anchor: .topLeading)
        .frame(width: layout.scaledSize.width, height: layout.scaledSize.height, alignment: .topLeading)
    }
    .scrollIndicators(.hidden)
    .scrollDisabled(layout.panelSize == layout.scaledSize)
    .frame(width: layout.panelSize.width, height: layout.panelSize.height)
    // A flat tint keeps every row equally legible over any desktop.
    .background(core.opacity(0.88), in: .rect(cornerRadius: 20))
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }

  private var core: Color { colorScheme == .dark ? .black : .white }
}

struct CheatsheetContent: View {
  let groups: [ShortcutGroup]
  let columnCount: Int

  var body: some View {
    HStack(alignment: .top, spacing: 44) {
      ForEach(Array(columns.enumerated()), id: \.offset) { _, groups in
        column(groups)
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .padding(28)
  }

  /// Sections keep reading order; the split minimizes the tallest column.
  private var columns: [[ShortcutGroup]] {
    let weights = groups.map { $0.rows.count + 2 }
    func split(from start: Int, into count: Int) -> (height: Int, cuts: [Int]) {
      if count <= 1 { return (weights[start...].reduce(0, +), []) }
      var best = (height: Int.max, cuts: [Int]())
      var height = 0
      for end in start..<(weights.count - count + 1) {
        height += weights[end]
        let rest = split(from: end + 1, into: count - 1)
        // `<=` favors a taller left column when splits tie.
        if max(height, rest.height) <= best.height {
          best = (max(height, rest.height), [end + 1] + rest.cuts)
        }
      }
      return best
    }
    guard !groups.isEmpty else { return [] }
    let bounds = [0] + split(from: 0, into: min(columnCount, groups.count)).cuts + [groups.count]
    return zip(bounds, bounds.dropFirst()).map { Array(groups[$0..<$1]) }
  }

  /// One grid per column keeps keys and labels aligned across sections.
  private func column(_ groups: [ShortcutGroup]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
      ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
        Text(group.title)
          .font(.system(size: 15, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
          .padding(.top, index == 0 ? 0 : 16)
          .padding(.bottom, 2)
          .gridCellUnsizedAxes(.horizontal)
        ForEach(group.rows, id: \.self) { row in
          GridRow {
            // Keys sit against their label however wide the column's longest chord.
            Chord(modifiers: row.modifiers, key: row.key).gridColumnAlignment(.trailing)
            Text(row.action).fixedSize()
            if let shifted = row.shifted {
              Chord(modifiers: shifted.modifiers, key: row.key)
                .padding(.leading, 12)
                .gridColumnAlignment(.trailing)
              Text(shifted.action).fixedSize()
            }
          }
          .accessibilityElement(children: .combine)
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

struct CheatsheetLayout: Equatable {
  /// Below this, labels stop being comfortable to read; the panel scrolls instead.
  static let minimumScale: CGFloat = 0.85

  let columns: Int
  let scale: CGFloat
  /// The content at `scale`, which scrolls when larger than `panelSize`.
  let scaledSize: CGSize
  let panelSize: CGSize

  /// Picks the column count that needs the least shrinking, then the one shaped most
  /// like the screen, so wide, tall, and small displays all get a balanced panel.
  /// `contentSizes[i]` is the natural size with `i + 1` columns.
  init(contentSizes: [CGSize], available: CGSize) {
    func fit(_ size: CGSize) -> CGFloat {
      min(1, available.width / size.width, available.height / size.height)
    }
    func mismatch(_ size: CGSize) -> CGFloat {
      abs(log((size.width / size.height) / (available.width / available.height)))
    }
    let best = contentSizes.indices.max { a, b in
      let (fitA, fitB) = (fit(contentSizes[a]), fit(contentSizes[b]))
      return fitA != fitB ? fitA < fitB : mismatch(contentSizes[a]) > mismatch(contentSizes[b])
    } ?? 0
    let content = contentSizes.indices.contains(best) ? contentSizes[best] : .zero
    columns = best + 1
    scale = max(Self.minimumScale, fit(content))
    scaledSize = CGSize(width: content.width * scale, height: content.height * scale)
    panelSize = CGSize(
      width: min(scaledSize.width, available.width), height: min(scaledSize.height, available.height)
    )
  }
}
