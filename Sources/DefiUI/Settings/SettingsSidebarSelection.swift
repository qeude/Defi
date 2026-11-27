import AppKit
import QuartzCore
import SwiftUI
import DefiMacOS

/// Draws the sidebar selection as one capsule that slides from row to row, in place of the table's
/// per-row highlight. Selection, keyboard navigation and accessibility stay the table's own.
struct SidebarSlidingSelection: NSViewRepresentable {
  /// Changes whenever the rows may have moved, such as when a search replaces them.
  let revision: AnyHashable

  func makeNSView(context: Context) -> Installer { Installer() }

  func updateNSView(_ view: Installer, context: Context) {
    DispatchQueue.main.async { view.update(animated: true) }
  }

  final class Installer: NSView {
    private weak var outline: NSOutlineView?
    private let indicator = NSView()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      DispatchQueue.main.async { [weak self] in self?.install() }
    }

    private func install() {
      guard outline == nil, let root = window?.contentView,
        let outline = Self.firstOutline(in: root)
      else { return }
      self.outline = outline
      outline.selectionHighlightStyle = .none
      indicator.wantsLayer = true
      indicator.layer?.cornerRadius = 8
      indicator.layer?.cornerCurve = .continuous
      indicator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
      outline.addSubview(indicator, positioned: .below, relativeTo: nil)
      let center = NotificationCenter.default
      observers = [
        center.addObserver(forName: NSOutlineView.selectionDidChangeNotification, object: outline, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.update(animated: true) }
        },
        center.addObserver(forName: NSView.frameDidChangeNotification, object: outline, queue: .main) {
          [weak self] _ in MainActor.assumeIsolated { self?.update(animated: false) }
        },
      ]
      update(animated: false)
    }

    func update(animated: Bool) {
      guard let outline else { return install() }
      let row = outline.selectedRow
      guard row >= 0, row < outline.numberOfRows else {
        // SwiftUI clears the selection before setting the next one; hide only if nothing follows.
        DispatchQueue.main.async { [weak self] in
          guard let self, let outline = self.outline, outline.selectedRow < 0 else { return }
          self.indicator.isHidden = true
        }
        return
      }
      let target = outline.rect(ofRow: row).insetBy(dx: 10, dy: 1)
      let wasHidden = indicator.isHidden
      indicator.isHidden = false
      indicator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
      guard animated, !wasHidden, indicator.frame != target,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      else {
        indicator.frame = target
        return
      }
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 1, 0.35, 1)
        indicator.animator().frame = target
      }
      // Hand the slide to the render server now: the new page builds on the main thread right after,
      // and a commit at the end of that work made the slide start late.
      CATransaction.flush()
    }

    private static func firstOutline(in view: NSView) -> NSOutlineView? {
      if let outline = view as? NSOutlineView { return outline }
      for subview in view.subviews {
        if let outline = firstOutline(in: subview) { return outline }
      }
      return nil
    }

    deinit {
      observers.forEach(NotificationCenter.default.removeObserver)
    }
  }
}
