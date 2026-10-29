import AppKit
import SwiftUI

struct SettingsSearchField: NSViewRepresentable {
  @Binding var text: String
  var moveToResults: (() -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = Field()
    field.placeholderString = "Search settings"
    field.setAccessibilityLabel("Search settings")
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.searchChanged(_:))
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    context.coordinator.moveToResults = moveToResults
    if field.stringValue != text { field.stringValue = text }
  }

  /// Editing suspends Defi's shortcuts. AppKit focuses the field as the window opens, during the
  /// menu click or key that opened it, which left the Settings column without keyboard
  /// navigation; only input in its own window, or code outside any event, starts editing.
  final class Field: NSSearchField {
    override func becomeFirstResponder() -> Bool {
      if let event = NSApp.currentEvent, event.window !== window { return false }
      return super.becomeFirstResponder()
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>
    var moveToResults: (() -> Void)?

    init(text: Binding<String>) { self.text = text }

    @objc func searchChanged(_ field: NSSearchField) {
      // Unfocused native cancel sends an action without a text-editing notification.
      if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      searchChanged(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
      guard command == #selector(NSResponder.moveDown(_:)), let moveToResults else { return false }
      moveToResults()
      return true
    }
  }
}
