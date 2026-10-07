import AppKit
import SwiftUI

struct SettingsSearchField: NSViewRepresentable {
  @Binding var text: String
  var moveToResults: (() -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
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
