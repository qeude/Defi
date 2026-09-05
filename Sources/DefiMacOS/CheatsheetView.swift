import SwiftUI

struct CheatsheetView: View {
  let groups: [ShortcutGroup]
  let size: CGSize
  let contentSizeChanged: (CGSize) -> Void
  @State private var contentSize: CGSize?

  var body: some View {
    let layout = size.width >= 950
      ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
    ScrollView([.horizontal, .vertical]) {
      layout {
        sections
      }
      .fixedSize(horizontal: true, vertical: true)
      .padding(24)
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
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
  }

  private var sections: some View {
    ForEach(groups, id: \.title) { group in
      VStack(alignment: .leading, spacing: 8) {
        Text(group.title)
          .font(.system(size: 18, weight: .semibold))
          .padding(.bottom, 8)
          .accessibilityAddTraits(.isHeader)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 9) {
          ForEach(group.shortcuts, id: \.keys) { shortcut in
            GridRow {
              Text(shortcut.keys)
                .font(.system(size: 13, weight: .medium))
                .fixedSize()
                .accessibilityLabel(shortcut.keys.replacingOccurrences(of: "✦", with: "Hyper "))
              Text(shortcut.command)
                .font(.system(size: 14))
                .fixedSize()
            }
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }

}
