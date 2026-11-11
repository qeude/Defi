import AppKit
import DefiModel
import SwiftUI

public struct RecentWindowsEntry: Equatable, Sendable {
  public let id: WindowID
  public let title: String
  public let processID: Int32?

  public init(id: WindowID, title: String, processID: Int32?) {
    self.id = id
    self.title = title
    self.processID = processID
  }
}

/// The recent windows switcher, on the cheat sheet's surface: one card per window, a
/// picture when Screen Recording allows it, else the app icon. It never takes focus and,
/// like Command-Tab, shows without animation.
@MainActor
public final class RecentWindowsController {
  static let panelTitle = "Defi recent windows"

  private var panel: NSPanel?
  private var hosting: NSHostingView<RecentWindowsView>?
  private var shown: (entries: [RecentWindowsEntry], monitorID: MonitorID?, previews: Bool)?

  public init() {}

  public var isVisible: Bool { panel != nil }

  public func show(
    _ entries: [RecentWindowsEntry], selection: Int, on monitorID: MonitorID?, previews: Bool
  ) {
    guard !entries.isEmpty else { return close() }
    let previews = previews && CGPreflightScreenCaptureAccess()
    if let hosting, shown?.entries == entries, shown?.monitorID == monitorID, shown?.previews == previews {
      hosting.rootView = RecentWindowsView(cards: hosting.rootView.cards, selection: selection)
      return
    }
    build(entries, selection: selection, on: monitorID, previews: previews)
  }

  public func close() {
    panel?.close()
    panel = nil
    hosting = nil
    shown = nil
  }

  private func build(
    _ entries: [RecentWindowsEntry], selection: Int, on monitorID: MonitorID?, previews: Bool
  ) {
    guard let screen = NSScreen.screens.first(where: {
      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint64Value == monitorID?.rawValue
    }) ?? NSScreen.main else { return }
    close()
    shown = (entries, monitorID, previews)
    let cards = entries.map { RecentWindowCard(entry: $0, previews: previews) }
    let bounds = screen.visibleFrame
    let size = CGSize(
      width: min(RecentWindowsView.contentWidth(count: cards.count), bounds.width - 96),
      height: RecentWindowsView.height)
    let frame = CGRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
      width: size.width, height: size.height)
    // With a screen, the content rect is relative to that screen's origin.
    let panel = RecentWindowsPanel(
      contentRect: frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
    panel.title = Self.panelTitle
    panel.setAccessibilityLabel("Recent windows")
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    let hosting = NSHostingView(rootView: RecentWindowsView(cards: cards, selection: selection))
    hosting.sizingOptions = []
    panel.contentView = hosting
    self.panel = panel
    self.hosting = hosting
    panel.orderFrontRegardless()
  }
}

private final class RecentWindowsPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

struct RecentWindowCard {
  static let preview = CGSize(width: 176, height: 110)

  let title: String
  let appName: String
  let icon: NSImage?
  /// The capture's layer contents and its size in points, when previews are allowed.
  let picture: (contents: AnyObject, size: CGSize)?

  init(entry: RecentWindowsEntry, previews: Bool) {
    let application = entry.processID.flatMap { NSRunningApplication(processIdentifier: $0) }
    appName = application?.localizedName ?? ""
    title = entry.title.isEmpty ? appName : entry.title
    icon = application?.icon
    picture = (previews ? WindowCaptureStore.shared.picture(entry.id) : nil)
      .flatMap { $0.size.width > 0 && $0.size.height > 0 ? ($0.contents, $0.size) : nil }
  }

  /// The picture fitted inside the preview box, never scaled up.
  var pictureSize: CGSize? {
    picture.map {
      let scale = min(Self.preview.width / $0.size.width, Self.preview.height / $0.size.height, 1)
      return CGSize(width: $0.size.width * scale, height: $0.size.height * scale)
    }
  }
}

struct RecentWindowsView: View {
  static let cardWidth = RecentWindowCard.preview.width + 16
  static let spacing: CGFloat = 8
  static let padding: CGFloat = 20
  static let height = RecentWindowCard.preview.height + 54 + 2 * padding

  static func contentWidth(count: Int) -> CGFloat {
    CGFloat(count) * cardWidth + CGFloat(max(count - 1, 0)) * spacing + 2 * padding
  }

  let cards: [RecentWindowCard]
  let selection: Int

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: Self.spacing) {
          ForEach(cards.indices, id: \.self) { index in
            card(cards[index], selected: index == selection).id(index)
          }
        }
        .padding(Self.padding)
      }
      .scrollIndicators(.hidden)
      .onAppear { proxy.scrollTo(selection, anchor: .center) }
      .onChange(of: selection) { proxy.scrollTo(selection) }
    }
    .defiPanelSurface()
  }

  private func card(_ card: RecentWindowCard, selected: Bool) -> some View {
    VStack(spacing: 8) {
      Group {
        if let picture = card.picture, let size = card.pictureSize {
          WindowPictureView(contents: picture.contents)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) { appIcon(card, size: 32).offset(x: -6, y: 6) }
        } else {
          appIcon(card, size: 64)
        }
      }
      .frame(width: RecentWindowCard.preview.width, height: RecentWindowCard.preview.height)
      Text(card.title)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(8)
    .frame(width: Self.cardWidth)
    .background(selected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(card.appName.isEmpty || card.appName == card.title
      ? card.title : "\(card.title), \(card.appName)")
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  @ViewBuilder private func appIcon(_ card: RecentWindowCard, size: CGFloat) -> some View {
    if let icon = card.icon {
      Image(nsImage: icon).resizable().frame(width: size, height: size)
    }
  }
}

/// A capture is a CGImage or an IOSurface: a layer shows either without copying it.
private struct WindowPictureView: NSViewRepresentable {
  let contents: AnyObject

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.contentsGravity = .resizeAspect
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    if (view.layer?.contents as AnyObject?) !== contents { view.layer?.contents = contents }
  }
}
