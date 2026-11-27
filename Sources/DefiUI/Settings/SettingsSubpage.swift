import AppKit
import SwiftUI
import DefiMacOS

/// The subpage open on the current settings page, which the page title shows as a breadcrumb.
@MainActor @Observable
final class SettingsSubpageNavigator {
  fileprivate(set) var title: String?
  fileprivate var close: (() -> Void)?

  func pop() {
    title = nil
    close?()
  }
}

/// Leaves the subpage an editor runs in; `dismiss` would close the whole Settings window.
struct CloseSettingsSubpageAction: Equatable {
  fileprivate let id: AnyHashable?
  fileprivate let action: () -> Void

  @MainActor func callAsFunction() { action() }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

extension EnvironmentValues {
  @Entry var closeSettingsSubpage = CloseSettingsSubpageAction(id: nil, action: {})
}

extension View {
  /// Slides `destination` over the page while `item` is set, and keeps the page alive underneath.
  func settingsSubpage<Item: Identifiable, Destination: View>(
    item: Binding<Item?>, title: @escaping (Item) -> String,
    @ViewBuilder destination: @escaping (Item) -> Destination
  ) -> some View {
    modifier(SettingsSubpageModifier(item: item, title: title, destination: destination))
  }
}

let settingsSubpageAnimation = Animation.smooth(duration: 0.3)

private struct SettingsSubpageModifier<Item: Identifiable, Destination: View>: ViewModifier {
  @Binding var item: Item?
  let title: (Item) -> String
  let destination: (Item) -> Destination
  @Environment(SettingsSubpageNavigator.self) private var navigator
  @State private var slide = SubpageSlide()
  @State private var closing = false

  func body(content: Content) -> some View {
    let open = item != nil
    let binding = $item
    let closingBinding = $closing
    let slide = slide
    let close = {
      guard !closingBinding.wrappedValue else { return }
      withAnimation(settingsSubpageAnimation) { closingBinding.wrappedValue = true }
      slide.slideOut { binding.wrappedValue = nil }
    }
    ZStack {
      content
        .opacity(open && !closing ? 0 : 1)
        .allowsHitTesting(!open)
        .accessibilityHidden(open)
      if let item {
        SubpageHost(slide: slide, content: destination(item)
          .environment(\.closeSettingsSubpage, CloseSettingsSubpageAction(id: AnyHashable(item.id), action: close))
          .onExitCommand(perform: close))
          .id(item.id)
      }
    }
    .clipped()
    .animation(settingsSubpageAnimation, value: item?.id)
    .onChange(of: item?.id, initial: true) {
      closing = false
      navigator.title = item.map(title)
      navigator.close = open ? close : nil
    }
    .onDisappear {
      navigator.title = nil
      navigator.close = nil
    }
  }
}

/// Slides a subpage with Core Animation on its own layer. A SwiftUI offset moves every AppKit control
/// inside the editor on the main thread each frame, which held the slide well under 120 Hz.
@MainActor
private final class SubpageSlide {
  weak var view: NSView?

  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  func slideIn() {
    guard let view, let layer = view.layer else { return }
    let offset = reduceMotion ? 0 : view.bounds.width
    layer.add(Self.animation("transform.translation.x", from: offset, to: 0), forKey: "slide")
    layer.add(Self.animation("opacity", from: 0, to: 1), forKey: "fade")
  }

  func slideOut(_ done: @escaping @MainActor () -> Void) {
    guard let view, let layer = view.layer else { return done() }
    let offset = reduceMotion ? 0 : view.bounds.width
    CATransaction.begin()
    CATransaction.setCompletionBlock { Task { @MainActor in done() } }
    layer.opacity = 0
    layer.add(Self.animation("transform.translation.x", from: 0, to: offset), forKey: "slide")
    layer.add(Self.animation("opacity", from: 1, to: 0), forKey: "fade")
    CATransaction.commit()
  }

  private static func animation(_ keyPath: String, from: CGFloat, to: CGFloat) -> CAAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.fromValue = from
    animation.toValue = to
    animation.damping = 35
    animation.stiffness = 300
    animation.mass = 1
    animation.duration = animation.settlingDuration
    animation.fillMode = .both
    animation.isRemovedOnCompletion = true
    return animation
  }
}

private struct SubpageHost<Content: View>: NSViewRepresentable {
  let slide: SubpageSlide
  let content: Content

  func makeNSView(context: Context) -> NSHostingView<Content> {
    let view = NSHostingView(rootView: content)
    view.sizingOptions = []
    view.wantsLayer = true
    slide.view = view
    // After the first layout, so the slide knows the page width.
    DispatchQueue.main.async { slide.slideIn() }
    return view
  }

  func updateNSView(_ view: NSHostingView<Content>, context: Context) {
    view.rootView = content
  }
}

/// Cancel and confirm buttons along the bottom of a subpage, where a sheet kept them in its toolbar.
struct SettingsSubpageActions<Actions: View>: View {
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack {
      Spacer()
      actions
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }
}

/// A whole row that opens a subpage, with a chevron at its trailing edge.
struct SettingsNavigationButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.label
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      Image(systemName: "chevron.forward")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .opacity(configuration.isPressed ? 0.55 : 1)
  }
}

extension ButtonStyle where Self == SettingsNavigationButtonStyle {
  static var settingsNavigation: SettingsNavigationButtonStyle { SettingsNavigationButtonStyle() }
}

/// The row that adds an item to a list: tinted, so it reads as the list's action.
struct SettingsAddLabel: View {
  let title: String
  var iconWidth: CGFloat?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "plus.circle.fill")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .frame(width: iconWidth)
      Text(title).fontWeight(.medium)
    }
    .foregroundStyle(Color.accentColor)
  }
}
