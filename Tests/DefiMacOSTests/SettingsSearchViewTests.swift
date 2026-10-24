import AppKit
import SwiftUI
import Testing

@testable import DefiMacOS

@MainActor
struct SettingsSearchViewTests {
  private func hostSettings() throws -> (NSWindow, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configURL = directory.appendingPathComponent("config.toml")
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: DefiSettingsView(configURL: configURL))
    return (window, directory)
  }

  private func descendants(_ window: NSWindow) -> [NSView] {
    func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    return window.contentView.map(views) ?? []
  }

  private func converge(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }

  private func arrowDown(_ window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
      charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
  }

  private func isVisibleInViewport(_ view: NSView) -> Bool {
    guard !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
      let scroll = view.enclosingScrollView else { return false }
    return !view.convert(view.visibleRect, to: scroll.contentView)
      .intersection(scroll.contentView.bounds).isEmpty
  }

  @Test
  func cancelAfterKeyboardSelectionRestoresPages() throws {
    // The settings view switches the activation policy of the shared test process.
    let policy = NSApplication.shared.activationPolicy()
    let (window, directory) = try hostSettings()
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(policy)
      try? FileManager.default.removeItem(at: directory)
    }
    func rows() -> Int? { descendants(window).compactMap { $0 as? NSTableView }.first?.numberOfRows }
    func shortcutFilter() -> String? {
      descendants(window).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "Search actions" }?.stringValue
    }
    #expect(converge { descendants(window).contains { $0 is NSSearchField } })
    let search = try #require(descendants(window).compactMap { $0 as? NSSearchField }.first)
    #expect(window.makeFirstResponder(search))
    let editor = try #require(search.currentEditor() as? NSTextView)
    editor.insertText("focus column left", replacementRange: NSRange(location: 0, length: 0))
    #expect(converge { rows() == 2 })
    window.sendEvent(try arrowDown(window))
    #expect(converge { shortcutFilter() == "focus-column first" }, "Down must select and reveal the actual shortcut action")
    #expect(search.currentEditor() == nil, "Down must transfer focus into the results")
    window.sendEvent(try arrowDown(window))
    #expect(converge { shortcutFilter() == "focus-column left" }, "Further arrows must navigate the native result list")
    #expect(converge {
      descendants(window).compactMap { $0 as? ShortcutRecorderButton }.contains {
        $0.accessibilityLabel() == "Record shortcut for focus-column left" && isVisibleInViewport($0)
      }
    }, "The selected shortcut's recorder must be visible inside the detail viewport")
    let cancel = try #require((search.cell as? NSSearchFieldCell)?.cancelButtonCell)
    cancel.performClick(search)
    #expect(search.stringValue == "")
    #expect(converge { rows() == SettingsPage.allCases.count }, "Native cancel must restore the settings pages after keyboard selection")
    #expect(shortcutFilter() ?? "" == "", "Native cancel must remove the exact shortcut filter")
    #expect(window.makeFirstResponder(search))
    let focusedEditor = try #require(search.currentEditor() as? NSTextView)
    focusedEditor.insertText("border width", replacementRange: NSRange(location: 0, length: 0))
    #expect(converge { rows() == 1 })
    #expect(search.currentEditor() === focusedEditor, "Typing must retain search focus")
    cancel.performClick(search)
    #expect(converge { rows() == SettingsPage.allCases.count }, "Cancel must also restore pages while search remains focused")
  }
}
