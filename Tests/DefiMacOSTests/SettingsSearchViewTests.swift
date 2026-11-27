import AppKit
import SwiftUI
import XCTest

@testable import DefiMacOS
@testable import DefiUI

/// XCTest, not Swift Testing: a synchronous XCTest pumps the main queue between checks, so the view's
/// reveal tasks run. A Swift Testing test holds the main actor while pumping, and they never would.
@MainActor
final class SettingsSearchViewTests: XCTestCase {
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
    try XCTUnwrap(NSEvent.keyEvent(
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

  func testCancelAfterKeyboardSelectionRestoresPages() throws {
    // The settings view switches the activation policy of the shared test process.
    let policy = NSApplication.shared.activationPolicy()
    let (window, directory) = try hostSettings()
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(policy)
      try? FileManager.default.removeItem(at: directory)
    }
    let sidebarRowCount = SettingsPage.allCases.count + SettingsPage.sidebarGroups.filter { $0.title != nil }.count
    func rows() -> Int? { descendants(window).compactMap { $0 as? NSTableView }.first?.numberOfRows }
    func shortcutFilter() -> String? {
      descendants(window).compactMap { $0 as? NSTextField }
        .first { $0.placeholderString == "Search shortcuts" }?.stringValue
    }
    XCTAssertTrue(converge { descendants(window).contains { $0 is NSSearchField } })
    let search = try XCTUnwrap(descendants(window).compactMap { $0 as? NSSearchField }.first)
    XCTAssertTrue(window.makeFirstResponder(search))
    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    editor.insertText("column first", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(converge { rows() == 2 })
    window.sendEvent(try arrowDown(window))
    XCTAssertTrue(converge { shortcutFilter() == "focus-column first" }, "Down must select and reveal the actual shortcut action")
    XCTAssertNil(search.currentEditor(), "Down must transfer focus into the results")
    window.sendEvent(try arrowDown(window))
    XCTAssertTrue(converge { shortcutFilter() == "move-column first" }, "Further arrows must navigate the native result list")
    XCTAssertTrue(converge {
      descendants(window).compactMap { $0 as? ShortcutRecorderButton }.contains {
        $0.accessibilityLabel() == "Record shortcut for move-column first" && isVisibleInViewport($0)
      }
    }, "The selected shortcut's recorder must be visible inside the detail viewport")
    let cancel = try XCTUnwrap((search.cell as? NSSearchFieldCell)?.cancelButtonCell)
    cancel.performClick(search)
    XCTAssertEqual(search.stringValue, "")
    XCTAssertTrue(converge { rows() == sidebarRowCount }, "Native cancel must restore the settings pages after keyboard selection")
    XCTAssertEqual(shortcutFilter() ?? "", "", "Native cancel must remove the exact shortcut filter")
    XCTAssertTrue(window.makeFirstResponder(search))
    let focusedEditor = try XCTUnwrap(search.currentEditor() as? NSTextView)
    focusedEditor.insertText("border width", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(converge { rows() == 1 })
    XCTAssertTrue(search.currentEditor() === focusedEditor, "Typing must retain search focus")
    cancel.performClick(search)
    XCTAssertTrue(converge { rows() == sidebarRowCount }, "Cancel must also restore pages while search remains focused")
  }

  func testTypingInTheShortcutSearchKeepsFocus() throws {
    let policy = NSApplication.shared.activationPolicy()
    let (window, directory) = try hostSettings()
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(policy)
      try? FileManager.default.removeItem(at: directory)
    }
    let sidebar = try XCTUnwrap({ () -> NSTableView? in
      _ = converge { descendants(window).contains { $0 is NSTableView } }
      return descendants(window).compactMap { $0 as? NSTableView }.first
    }())
    let keyboard = try XCTUnwrap(SettingsPage.sidebarRowIndex(of: .keyboard))
    sidebar.selectRowIndexes([keyboard], byExtendingSelection: false)
    func field() -> NSTextField? {
      descendants(window).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search shortcuts" }
    }
    XCTAssertTrue(converge { field() != nil })
    let search = try XCTUnwrap(field())
    XCTAssertTrue(window.makeFirstResponder(search))
    for (offset, character) in "cen".enumerated() {
      let editor = try XCTUnwrap(search.currentEditor() as? NSTextView, "Focus left the field before character \(offset + 1)")
      editor.insertText(String(character), replacementRange: NSRange(location: offset, length: 0))
      _ = converge({ false }, timeout: 0.2)
    }
    XCTAssertEqual(search.stringValue, "cen")
    XCTAssertNotNil(search.currentEditor(), "The results appearing must not take focus from the search field")
    sidebar.selectRowIndexes([0], byExtendingSelection: false)
    _ = converge({ false }, timeout: 0.3)
    sidebar.selectRowIndexes([keyboard], byExtendingSelection: false)
    _ = converge({ false }, timeout: 0.3)
    XCTAssertEqual(search.stringValue, "cen", "Switching pages must keep a typed shortcut search")

    let settings = try XCTUnwrap(descendants(window).compactMap { $0 as? NSSearchField }.first { $0.placeholderString == "Search settings" })
    XCTAssertTrue(window.makeFirstResponder(settings))
    try XCTUnwrap(settings.currentEditor() as? NSTextView).insertText("holding the main modifier", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(converge { sidebar.numberOfRows == 1 })
    window.sendEvent(try arrowDown(window))
    XCTAssertTrue(converge { search.stringValue.isEmpty }, "Revealing a Keyboard option must clear the shortcut search that hides it")
  }

  func testKeyboardShortcutsResultScrollsTheShortcutListBackToItsSection() throws {
    let policy = NSApplication.shared.activationPolicy()
    let (window, directory) = try hostSettings()
    defer {
      window.close()
      NSApplication.shared.setActivationPolicy(policy)
      try? FileManager.default.removeItem(at: directory)
    }
    func rows() -> Int? { descendants(window).compactMap { $0 as? NSTableView }.first?.numberOfRows }
    // The full shortcut list is the tallest visible scroll view on the Keyboard page.
    func list() -> NSScrollView? {
      descendants(window).compactMap { $0 as? NSScrollView }
        .filter { !$0.isHiddenOrHasHiddenAncestor && !($0.documentView is NSTableView) }
        .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    XCTAssertTrue(converge { descendants(window).contains { $0 is NSTableView } })
    let sidebar = try XCTUnwrap(descendants(window).compactMap { $0 as? NSTableView }.first)
    sidebar.selectRowIndexes([try XCTUnwrap(SettingsPage.sidebarRowIndex(of: .keyboard))], byExtendingSelection: false)
    XCTAssertTrue(converge { (list()?.documentView?.frame.height ?? 0) > 3000 })
    let scroll = try XCTUnwrap(list())
    let document = try XCTUnwrap(scroll.documentView)
    document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertTrue(converge { scroll.contentView.bounds.minY > 2000 }, "The list must start scrolled far past its first sections")
    let pages = sidebar.numberOfRows
    let search = try XCTUnwrap(descendants(window).compactMap { $0 as? NSSearchField }
      .first { $0.placeholderString == "Search settings" })
    XCTAssertTrue(window.makeFirstResponder(search))
    try XCTUnwrap(search.currentEditor() as? NSTextView).insertText("Keyboard shortcuts", replacementRange: NSRange(location: 0, length: 0))
    XCTAssertTrue(converge { (rows() ?? 0) > 0 && rows() != pages })
    window.sendEvent(try arrowDown(window))
    XCTAssertTrue(converge { scroll.contentView.bounds.minY < 600 },
      "Choosing Keyboard shortcuts must scroll the full list back to that section")
  }
}
