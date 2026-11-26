import AppKit
import CoreGraphics
import DefiIPC
import Synchronization
import XCTest

/// Journeys that live in the daemon, run against the real `defi-daemon` binary. That daemon
/// manages every window on the display and drags through the HID tap, so these cases run only
/// in the defi-e2e VM, where script/test_vm.sh names its binaries.
extension DesktopE2ETests {
  func testWindowDragPreviewsThenCommitsOnRelease() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[layout]\ndefault_column_width = 0.3\n")
    defer { daemon.stop() }
    var windows: [UInt64: DesktopFixtureWindow] = [:]
    defer { windows.values.forEach { $0.close() } }
    func open(minimumHeight: Double? = nil) throws -> UInt64 {
      let window = try lane.openWindow(minimumHeight: minimumHeight, daemon: daemon)
      windows[window.windowID] = window
      return window.windowID
    }

    var workspace = try daemon.switchToEmptyWorkspace()
    let a = try open(), b = try open(), c = try open()
    try daemon.run("focus-column first")
    try daemon.run("focus-column right")
    try daemon.run("join-window left")
    XCTAssertTrue(daemon.converge(workspace, to: [[a, b], [c]]), daemon.diagnostics(workspace))
    let display = CGDisplayBounds(CGMainDisplayID())
    for (id, window) in windows {
      let frame = try window.frame()
      XCTAssertTrue(frame.minX >= display.minX && frame.maxX <= display.maxX,
        "Fixture \(id) must be fully on screen: \(frame)")
    }

    func frame(_ id: UInt64) throws -> CGRect { try XCTUnwrap(windows[id]).frame() }
    /// While a lone column's window is carried, the columns after it close up by its width and a gap.
    func closedUp(_ x: Double, carrying id: UInt64) throws -> Double {
      let carried = try frame(id), columns = try daemon.columns(workspace)
      guard columns.contains([id]), x > carried.maxX else { return x }
      let next = try columns.joined().map(frame).map(\.minX).filter { $0 > carried.maxX }.min()
      return next.map { x - carried.width - ($0 - carried.maxX) } ?? x
    }
    func check(_ name: String, drag id: UInt64, to target: CGPoint, expect: [[UInt64]]?,
      preview: (String) -> Bool) throws {
      let before = try daemon.columns(workspace)
      let carried = CGPoint(x: try closedUp(target.x, carrying: id), y: target.y)
      let drag = try daemon.drag(try XCTUnwrap(windows[id]), to: carried, workspace: workspace)
      XCTAssertEqual(drag.held, before, "\(name): membership must not change while the button is held")
      let shown = try XCTUnwrap(drag.previews.last, "\(name): a drop target must be previewed while held")
      XCTAssertTrue(preview(shown), "\(name): unexpected preview \(drag.previews)")
      XCTAssertEqual(drag.drops, [shown], "\(name): release must commit the previewed target once")
      let converged = daemon.converge(workspace, to: expect ?? before)
      if !converged {
        let later = (try? daemon.trace())?.map { "\($0.at) \($0.event)" }
          .filter { !$0.contains(" fresh-read") && !$0.contains(" window-snapshot") && !$0.contains("frame-submit source=desktop-sync") } ?? []
        XCTFail("\(name): unexpected membership; \(daemon.diagnostics(workspace))\nDRAG\n"
          + drag.events.suffix(60).joined(separator: "\n") + "\nLATER\n" + later.joined(separator: "\n"))
      }
    }

    let titleY = try frame(a).minY + 12
    // Column indices count the strip as shown while held, without a column the window leaves empty.
    try check("release over its own column", drag: c, to: CGPoint(x: try frame(c).midX + 40, y: titleY),
      expect: nil, preview: { $0 == "column(index: 1)" })
    try check("extract from a stack", drag: b,
      to: CGPoint(x: try frame(c).midX + 0.35 * frame(c).width, y: titleY), expect: [[a], [c], [b]],
      preview: { $0 == "column(index: 2)" })
    try check("move a column across two", drag: b,
      to: CGPoint(x: try frame(a).midX - 0.35 * frame(a).width, y: titleY), expect: [[b], [a], [c]],
      preview: { $0 == "column(index: 0)" })
    try check("stack into the column under the pointer", drag: a,
      to: CGPoint(x: try frame(c).midX, y: try frame(c).maxY - 40), expect: [[b], [c, a]],
      preview: { $0.hasPrefix("stack(") && $0.hasSuffix("row: 1))") })

    // Two windows that each need over half the height cannot share a column.
    workspace = try daemon.switchToEmptyWorkspace()
    let tall = 0.6 * (NSScreen.main?.visibleFrame.height ?? display.height)
    let f = try open(minimumHeight: tall), g = try open(minimumHeight: tall)
    XCTAssertTrue(daemon.converge(workspace, to: [[f], [g]]), daemon.diagnostics(workspace))
    // At the screen's top edge the pointer reaches a column's top, with or without a menu bar.
    try check("rejected stack", drag: g, to: CGPoint(x: try frame(f).midX, y: display.minY),
      expect: [[f], [g]], preview: { $0.hasPrefix("rejectedStack(") })
  }

  func testStackConstraintsHoldOnRealWindows() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[layout]\ndefault_column_width = 0.4\n")
    defer { daemon.stop() }
    var windows: [String: DesktopFixtureWindow] = [:]
    defer { windows.values.forEach { $0.close() } }
    let workspace = try daemon.switchToEmptyWorkspace()
    func open(_ name: String, minimumHeight: Double? = nil) throws -> UInt64 {
      try daemon.run("workspace \(workspace)")
      let window = try lane.openWindow(minimumHeight: minimumHeight, daemon: daemon)
      windows[name] = window
      return window.windowID
    }
    func close(_ names: String...) throws {
      for name in names { windows.removeValue(forKey: name)?.close() }
      // Closing hands native focus to another app, which Defi follows to its workspace.
      try daemon.run("workspace \(workspace)")
      XCTAssertTrue(daemon.settle(windows.values))
    }
    func frames(_ names: String...) throws -> [CGRect] { try names.map { try XCTUnwrap(windows[$0]).frame() } }

    _ = try open("plain")
    let lone = try frames("plain")[0].height
    let reserve = min(512, (lone / 2).rounded())
    defer { _ = try? daemon.run("set-reserved-area bottom 0") }

    _ = try open("tall", minimumHeight: 0.6 * lone)
    let tall2 = try open("tall2", minimumHeight: 0.6 * lone)
    XCTAssertTrue(daemon.settle(windows.values))
    let columns = try daemon.columns(workspace), before = try frames("tall", "tall2")
    let join = try daemon.send("join-window left")
    XCTAssertFalse(join.ok)
    XCTAssertTrue(join.message.hasPrefix("cannot join: stack needs"), join.message)
    XCTAssertTrue(daemon.settle(windows.values))
    XCTAssertEqual(try daemon.columns(workspace), columns, "A refused join must change nothing")
    XCTAssertEqual(try frames("tall", "tall2"), before)
    XCTAssertEqual(try daemon.status("focused"), "\(tall2)")
    try close("tall", "tall2")

    let s1 = try open("s1", minimumHeight: 0.42 * lone)
    let s2 = try open("s2", minimumHeight: 0.42 * lone)
    XCTAssertTrue(daemon.settle(windows.values))
    try daemon.run("join-window left")
    XCTAssertTrue(daemon.converge(workspace) { $0.contains([s1, s2]) }, daemon.diagnostics(workspace))
    XCTAssertTrue(daemon.settle(windows.values))
    let stacked = try frames("s1", "s2")
    XCTAssertEqual(stacked[0].minX, stacked[1].minX, accuracy: 1, "The joined windows must share a column on screen")
    try daemon.run("set-reserved-area bottom \(Int(reserve))")
    XCTAssertTrue(daemon.converge(workspace) { columns in
      columns.firstIndex(of: [s1]).map { columns.indices.contains($0 + 1) && columns[$0 + 1] == [s2] } == true
    }, "A stack that no longer fits must separate to its right; \(daemon.diagnostics(workspace))")
    XCTAssertTrue(daemon.settle(windows.values))
    let separated = try frames("s1", "s2")
    XCTAssertGreaterThan(separated[1].minX, separated[0].maxX, "s2 must sit right of s1 on screen: \(separated)")
    XCTAssertEqual(try daemon.status("focused"), "\(s2)", "Separation must keep focus on the same window")
    XCTAssertTrue(pumpRunLoop(until: { (try? windows["s2"]?.hasNativeFocus()) == true }, timeout: 3),
      "s2 must keep native focus")
    try daemon.run("set-reserved-area bottom 0")
    XCTAssertTrue(daemon.settle(windows.values))
    XCTAssertFalse(try daemon.columns(workspace).contains([s1, s2]), "Growth must not merge columns back")
    try close("s1", "s2")

    let huge = try open("huge", minimumHeight: 0.9 * lone)
    try daemon.run("set-reserved-area bottom \(Int(reserve))")
    XCTAssertTrue(daemon.settle(windows.values))
    XCTAssertTrue(pumpRunLoop(until: {
      (try? daemon.status("oversized-stack-windows"))?.split(separator: ",").contains("\(huge)") == true
    }, timeout: 3), "status: \(String(describing: try? daemon.status("oversized-stack-windows")))")
    XCTAssertEqual(try frames("huge")[0].height, 0.9 * lone, accuracy: 2, "An oversized window sits at its minimum")
    XCTAssertEqual(try daemon.appliedWrites(to: huge, over: 3), 0, "An oversized window must not be resized again")
  }

  func testScrollGestureTapsOncePerColumnItWouldLandOn() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: """
      [layout]
      default_column_width = 0.3
      [input]
      scroll_gestures = true
      scroll_gesture_modifier = "ctrl+alt"
      """)
    defer { daemon.stop() }
    var windows: [DesktopFixtureWindow] = []
    defer { windows.forEach { $0.close() } }
    let workspace = try daemon.switchToEmptyWorkspace()
    for _ in 1...6 { windows.append(try lane.openWindow(minimumHeight: nil, daemon: daemon)) }
    try daemon.run("focus-column first")
    XCTAssertTrue(daemon.converge(workspace) { $0.count == 6 } && daemon.settle(windows))

    /// Posts one modified two-finger swipe of `steps` deltas, `interval` apart, and returns the
    /// landings its haptic taps reported.
    func swipe(_ steps: Int, by delta: Int32, every interval: TimeInterval) throws -> [Int] {
      var recording = try daemon.startRecording()
      let display = CGDisplayBounds(CGMainDisplayID())
      CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: display.midX, y: display.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
      let events: [(phase: Int64, dx: Int32)] = [(1, 0)] + Array(repeating: (2, delta), count: steps) + [(4, 0)]
      for event in events {
        guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
          wheel1: 0, wheel2: event.dx, wheel3: 0) else { continue }
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
        scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(event.dx))
        scroll.flags = [.maskControl, .maskAlternate]
        scroll.post(tap: .cghidEventTap)
        let deadline = Date().addingTimeInterval(interval)
        repeat { Thread.sleep(forTimeInterval: 0.005); try daemon.record(&recording) } while Date() < deadline
      }
      _ = pumpRunLoop(until: { daemon.settled() }, timeout: 3)
      try daemon.record(&recording)
      let tap = "scroll-pan-haptic "
      return recording.events.filter { $0.hasPrefix(tap) }
        .compactMap { $0.split(separator: " ").last.flatMap { Int($0.dropFirst("landing=".count)) } }
    }

    let slow = try swipe(40, by: -40, every: 0.02)
    XCTAssertGreaterThanOrEqual(slow.count, 2, "A slow swipe across columns must tap for each; taps=\(slow)")
    XCTAssertEqual(slow, slow.sorted(), "Swiping one way must tap for columns in order; taps=\(slow)")
    XCTAssertEqual(Set(slow).count, slow.count, "No column may tap twice; taps=\(slow)")

    try daemon.run("focus-column first")
    XCTAssertTrue(daemon.settle(windows))
    let flick = try swipe(4, by: -400, every: 0.004)
    XCTAssertLessThanOrEqual(flick.count, 1, "A flick across columns must tap at most once; taps=\(flick)")
  }

  func testCloseWindowWaitsForTheAppToDestroyIt() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[layout]\ndefault_column_width = 0.3\n")
    defer { daemon.stop() }
    var windows: [DesktopFixtureWindow] = []
    defer { windows.forEach { $0.close() } }
    func open(refusesClose: Bool = false) throws -> UInt64 {
      let window = try lane.openWindow(refusesClose: refusesClose, daemon: daemon)
      windows.append(window)
      return window.windowID
    }
    func managed() throws -> Set<UInt64> {
      Set(try daemon.workspaces().monitors.flatMap(\.workspaces).flatMap(\.windows).map(\.id))
    }
    func gone(_ id: UInt64) -> Bool { pumpRunLoop(until: { (try? managed())?.contains(id) == false }, timeout: 5) }

    let workspace = try daemon.switchToEmptyWorkspace()
    let a = try open(), keeper = try open(refusesClose: true), stacked = try open()
    try daemon.run("join-window left")
    XCTAssertTrue(daemon.converge(workspace, to: [[a], [keeper, stacked]]), daemon.diagnostics(workspace))

    XCTAssertEqual(try daemon.run("close-window"), "closing \(stacked)")
    XCTAssertTrue(gone(stacked), "A stacked window must close; \(daemon.diagnostics(workspace))")
    XCTAssertTrue(daemon.converge(workspace, to: [[a], [keeper]]), daemon.diagnostics(workspace))

    try daemon.run("workspace \(workspace)")
    try daemon.run("focus-column last")
    XCTAssertTrue(pumpRunLoop(until: { (try? daemon.status("focused")) == "\(keeper)" }, timeout: 3))
    XCTAssertEqual(try daemon.run("close-window"), "closing \(keeper)")
    XCTAssertFalse(gone(keeper), "A window whose app refuses to close must stay managed")
    XCTAssertEqual(try daemon.columns(workspace), [[a], [keeper]])
    XCTAssertEqual(try daemon.status("focused"), "\(keeper)", "A refused close must keep focus")

    let floating = try open()
    try daemon.run("toggle-floating")
    XCTAssertEqual(try daemon.run("close-window"), "closing \(floating)")
    XCTAssertTrue(gone(floating), "A floating window must close")

    try daemon.run("workspace \(workspace)")
    try daemon.run("focus-column first")
    XCTAssertTrue(pumpRunLoop(until: { (try? daemon.status("focused")) == "\(a)" }, timeout: 3))
    XCTAssertTrue(pumpRunLoop(until: { daemon.settled() }, timeout: 5))
    let toggled = try daemon.run("toggle-overview")
    XCTAssertTrue(pumpRunLoop(until: { (try? daemon.status("overview")) == "open" }, timeout: 3),
      "toggle-overview: \(toggled); \((try? daemon.run("status"))?.split(separator: " ").filter { $0.hasPrefix("overview") } ?? [])"
        + "\n\(daemon.logTail())")
    try daemon.run("close-window")
    XCTAssertTrue(gone(a), "In the Overview, close-window must close the selected card's window")
    try daemon.run("toggle-overview")

    XCTAssertFalse(try daemon.send("close-window 1").ok, "An unknown ID must be refused")
  }

  func testColumnMoveCarriesTheFocusedFloatingWindow() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[workspaces]\nnames = [\"a\", \"b\"]\n")
    defer { daemon.stop() }
    try daemon.run("workspace a")
    let tiled = try lane.openWindow(daemon: daemon)
    defer { tiled.close() }
    let floating = try lane.openWindow(daemon: daemon)
    defer { floating.close() }
    try daemon.run("toggle-floating")
    XCTAssertTrue(daemon.settle([tiled, floating]))
    XCTAssertEqual(try daemon.status("focused"), "\(floating.windowID)")

    try daemon.run("move-column-to-workspace b")

    func members(_ workspace: String) throws -> [UInt64] {
      try XCTUnwrap(daemon.workspaces().monitors.flatMap(\.workspaces).first { $0.id == workspace }).windows.map(\.id)
    }
    XCTAssertTrue(pumpRunLoop(until: { (try? members("b")) == [floating.windowID] && daemon.settled() }, timeout: 5),
      "b=\(String(describing: try? members("b"))) \(daemon.diagnostics("a"))")
    XCTAssertEqual(try daemon.columns("a"), [[tiled.windowID]])
    XCTAssertEqual(try daemon.status("focused"), "\(floating.windowID)")

    try daemon.run("toggle-overview")
    XCTAssertTrue(pumpRunLoop(until: { (try? daemon.status("overview")) == "open" }, timeout: 3))
    try daemon.run("move-column-to-workspace a")
    XCTAssertTrue(pumpRunLoop(until: { (try? members("a"))?.contains(floating.windowID) == true }, timeout: 5),
      "In the Overview: a=\(String(describing: try? members("a")))")
    XCTAssertEqual(try daemon.columns("a"), [[tiled.windowID]])
    try daemon.run("toggle-overview")
    XCTAssertTrue(pumpRunLoop(until: { (try? daemon.status("overview")) != "open" && daemon.settled() }, timeout: 5))
    XCTAssertEqual(try daemon.status("focused"), "\(floating.windowID)")

    guard let main = NSScreen.screens.first?.frame, let other = NSScreen.screens.dropFirst().first?.frame else {
      try notRun(lane: "two-display", reason: "requires 2 displays, found \(NSScreen.screens.count)")
    }
    let (dx, dy) = (other.midX - main.midX, other.midY - main.midY)
    let direction = abs(dx) >= abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "up" : "down")
    func monitor(of id: UInt64) throws -> UInt64? {
      try daemon.workspaces().monitors.first { $0.workspaces.contains { $0.windows.contains { $0.id == id } } }?.id
    }
    let source = try monitor(of: tiled.windowID)

    try daemon.run("move-column-to-monitor \(direction)")

    XCTAssertTrue(pumpRunLoop(until: {
      (try? monitor(of: floating.windowID)).flatMap { $0 } != source && daemon.settled()
    }, timeout: 5), "floating monitor=\(String(describing: try? monitor(of: floating.windowID))) source=\(String(describing: source))")
    XCTAssertEqual(try monitor(of: tiled.windowID), source)
    XCTAssertEqual(try daemon.status("focused"), "\(floating.windowID)")
  }

  func testPinnedColumnStaysInPlaceAcrossWorkspaces() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: """
      [workspaces]
      names = ["a", "b"]
      [input]
      scroll_gestures = true
      scroll_gesture_modifier = "ctrl+alt"
      """)
    defer { daemon.stop() }
    try daemon.run("workspace a")
    let pinned = try lane.openWindow(daemon: daemon)
    defer { pinned.close() }
    let strip = try (0..<3).map { _ in try lane.openWindow(daemon: daemon) }
    defer { strip.forEach { $0.close() } }
    let all = [pinned] + strip
    try daemon.run("focus-window-id \(pinned.windowID)")
    try daemon.run("pin-column left")
    XCTAssertTrue(daemon.settle(all))
    let pinnedFrame = try pinned.frame()
    func members(_ workspace: String) throws -> [UInt64] {
      try XCTUnwrap(daemon.workspaces().monitors.flatMap(\.workspaces).first { $0.id == workspace }).windows.map(\.id)
    }
    // No strip window rests across the pinned column's edge, wherever keys or swipes scroll.
    func checkStrip(_ action: String) throws {
      XCTAssertTrue(daemon.settle(all), "\(action) must settle")
      XCTAssertEqual(try pinned.frame(), pinnedFrame, "The pinned column must stay put after \(action)")
      let edge = pinnedFrame.maxX
      for window in strip {
        let frame = try window.frame()
        XCTAssertFalse(frame.minX < edge - 1 && frame.maxX > edge + 1,
          "Window \(window.windowID) straddles the pinned edge at \(frame) after \(action)")
      }
    }
    for _ in 0..<4 {
      try daemon.run("focus-column right")
      try checkStrip("focus-column right")
    }
    var swipedTo = Set<String>()
    for (steps, delta) in [(12, Int32(40)), (25, 40), (8, -60), (30, -40), (4, 400), (4, -400)] {
      postSwipe(steps: steps, dx: delta)
      try checkStrip("a swipe of \(steps) × \(delta)")
      swipedTo.insert(try daemon.status("focused") ?? "")
    }
    XCTAssertGreaterThan(swipedTo.count, 1, "The swipes must scroll the strip: \(swipedTo)")

    // A vertical swipe switches workspace around the pinned column.
    postSwipe(steps: 20, dy: -60)
    XCTAssertTrue(daemon.settle(all))
    XCTAssertNotEqual(try daemon.status("workspace"), "a", "The vertical swipe must switch workspace")
    XCTAssertEqual(try pinned.frame(), pinnedFrame, "The pinned column must stay through a vertical swipe")
    try daemon.run("workspace b")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try pinned.frame(), pinnedFrame, "The pinned column must stay for every workspace")
    XCTAssertEqual(try members("b"), [pinned.windowID])
    _ = try daemon.send("move-column-to-workspace a")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try members("b"), [pinned.windowID], "The pinned column must refuse another workspace")

    try daemon.run("workspace a")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try pinned.frame(), pinnedFrame)
    XCTAssertEqual(Set(try members("a")), Set(all.map(\.windowID)))
  }

  func testScratchpadShowsParksAndFollowsWorkspaces() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[workspaces]\nnames = [\"a\", \"b\"]\n")
    defer { daemon.stop() }
    try daemon.run("workspace a")
    let tiled = try lane.openWindow(daemon: daemon)
    defer { tiled.close() }
    let scratch = try lane.openWindow(daemon: daemon)
    defer { scratch.close() }
    let all = [tiled, scratch]
    XCTAssertTrue(daemon.settle(all))
    let display = CGDisplayBounds(CGMainDisplayID())
    func parked() throws -> Bool {
      let frame = try scratch.frame()
      return frame.minX >= display.maxX - 2 || frame.maxX <= display.minX + 2
    }

    try daemon.run("focus-window-id \(scratch.windowID)")
    try daemon.run("toggle-scratchpad-window")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertTrue(try parked(), "A window added to a hidden scratchpad must park: \(String(describing: try? scratch.frame()))")
    XCTAssertEqual(try daemon.status("focused"), "\(tiled.windowID)")

    try daemon.run("toggle-scratchpad")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertFalse(try parked(), "toggle-scratchpad must show the window")
    XCTAssertEqual(try daemon.status("focused"), "\(scratch.windowID)")
    let shownFrame = try scratch.frame()

    try daemon.run("workspace b")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try scratch.frame(), shownFrame, "A shown scratchpad must follow the workspace switch")

    // On an empty workspace nothing takes focus from the parked window: it must stay parked.
    try daemon.run("toggle-scratchpad")
    XCTAssertTrue(daemon.settle(all))
    _ = pumpRunLoop(until: { false }, timeout: 1)
    XCTAssertTrue(try parked(), "The scratchpad must stay parked: \(daemon.diagnostics("b"))")

    // Native focus may linger on the parked window; it must not undo the switch.
    try daemon.run("workspace a")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try daemon.status("workspace"), "a")
    try daemon.run("toggle-scratchpad")
    XCTAssertTrue(daemon.settle(all))
    XCTAssertEqual(try scratch.frame(), shownFrame, "The scratchpad must show where it was")
  }

  /// Posts one two-finger swipe with the gesture modifier held, over the display's centre.
  private func postSwipe(steps: Int, dx: Int32 = 0, dy: Int32 = 0, every interval: TimeInterval = 0.016) {
    let display = CGDisplayBounds(CGMainDisplayID())
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
      mouseCursorPosition: CGPoint(x: display.midX, y: display.midY), mouseButton: .left)?.post(tap: .cghidEventTap)
    let events: [(phase: Int64, dx: Int32, dy: Int32)] =
      [(1, 0, 0)] + Array(repeating: (2, dx, dy), count: steps) + [(4, 0, 0)]
    for event in events {
      guard let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: event.dy, wheel2: event.dx, wheel3: 0) else { continue }
      scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
      scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(event.dy))
      scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(event.dx))
      scroll.flags = [.maskControl, .maskAlternate]
      scroll.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: interval)
    }
  }

  private func daemonLane() throws -> DesktopDaemonLane {
    let environment = ProcessInfo.processInfo.environment
    var virtualMachine: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.hv_vmm_present", &virtualMachine, &size, nil, 0) == 0, virtualMachine == 1,
      let daemon = environment["DEFI_E2E_DAEMON_BINARY"], let fixture = environment["DEFI_E2E_CLAMP_FIXTURE_BINARY"]
    else {
      try notRun(lane: "vm-daemon", reason: "runs the real daemon and HID drags only in the defi-e2e VM (script/test_vm.sh)")
    }
    _ = try preflight()
    guard FileManager.default.isExecutableFile(atPath: daemon), FileManager.default.isExecutableFile(atPath: fixture) else {
      throw DesktopDaemon.Failure("DEFI_E2E_DAEMON_BINARY and DEFI_E2E_CLAMP_FIXTURE_BINARY must name executables")
    }
    return DesktopDaemonLane(daemonBinary: daemon, fixtureBinary: fixture) { self.pumpRunLoop(until: $0, timeout: $1) }
  }
}

@MainActor
struct DesktopDaemonLane {
  let daemonBinary: String
  let fixtureBinary: String
  let pump: (() -> Bool, TimeInterval) -> Bool

  func startDaemon(config: String) throws -> DesktopDaemon {
    try DesktopDaemon(binary: daemonBinary, config: config, pump: pump)
  }

  /// Opens one fixture window and waits until the daemon tiles it, focused, as the last column.
  func openWindow(minimumHeight: Double? = nil, refusesClose: Bool = false, daemon: DesktopDaemon) throws
    -> DesktopFixtureWindow
  {
    let window = try DesktopFixtureWindow(
      binary: fixtureBinary, minimumHeight: minimumHeight, refusesClose: refusesClose, pump: pump)
    do {
      // Constraints are read when discovery adopts the window, a few hundred ms after it appears.
      guard pump({ (try? daemon.tiledWindowIDs())?.contains(window.windowID) == true }, 8) else {
        throw DesktopDaemon.Failure("Window \(window.windowID) was not adopted; \(daemon.logTail())")
      }
      try daemon.run("focus-column last")
      guard pump({ (try? daemon.status("focused")) == "\(window.windowID)" }, 3) else {
        throw DesktopDaemon.Failure(
          "Window \(window.windowID) did not take focus: focused=\(String(describing: try? daemon.status("focused")))")
      }
      return window
    } catch {
      window.close()
      throw error
    }
  }
}

@MainActor
final class DesktopDaemon {
  struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private let process = Process()
  private let directory: URL
  private let socketURL: URL
  private let pump: (() -> Bool, TimeInterval) -> Bool

  init(binary: String, config: String, pump: @escaping (() -> Bool, TimeInterval) -> Bool) throws {
    self.pump = pump
    // A Unix socket path must stay under 104 bytes; the per-user temporary directory is too deep.
    directory = URL(filePath: "/tmp/defi-e2e-\(getpid())-\(UUID().uuidString.prefix(8))")
    socketURL = directory.appending(path: "daemon.sock")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      let configURL = directory.appending(path: "config.toml")
      try config.write(to: configURL, atomically: true, encoding: .utf8)
      let log = directory.appending(path: "daemon.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      // The daemon has no topology path option: the guest's store is set aside, so no
      // earlier workspaces are restored, and put back when the daemon exits.
      if FileManager.default.fileExists(atPath: Self.topologyURL.path) {
        try FileManager.default.moveItem(at: Self.topologyURL, to: topologyBackupURL)
      }
      process.executableURL = URL(filePath: binary)
      process.arguments = ["--config", configURL.path, "--socket", socketURL.path]
      process.standardOutput = try FileHandle(forWritingTo: log)
      process.standardError = process.standardOutput
      try process.run()
      guard pump({ self.process.isRunning && (try? self.status("session")) == "active"
        && (try? self.status("monitors")).map { !$0.hasPrefix("0") } == true }, 15)
      else { throw Failure("defi-daemon did not start managing windows: \(logTail())") }
    } catch {
      stop()
      throw error
    }
  }

  private static let topologyURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Defi/workspace-topology.json")
  private var topologyBackupURL: URL { directory.appending(path: "workspace-topology.json") }

  /// SIGTERM restores every window and removes the socket, as `defi quit` does.
  func stop() {
    if process.isRunning {
      process.terminate()
      if !pump({ !self.process.isRunning }, 10) { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: Self.topologyURL)
    try? FileManager.default.moveItem(at: topologyBackupURL, to: Self.topologyURL)
    try? FileManager.default.removeItem(at: directory)
  }

  func send(_ command: String) throws -> CommandResponse { try sendCommand(command, to: socketURL) }

  @discardableResult
  func run(_ command: String) throws -> String {
    let response = try send(command)
    guard response.ok else { throw Failure("\(command): \(response.message)") }
    return response.message
  }

  func status(_ key: String) throws -> String? {
    try run("status").split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
  }

  func settled() -> Bool {
    guard let status = try? run("status") else { return false }
    return ["axPending=false", "focusPending=false", "animating=false", "drift=0[", "settling=0 "]
      .allSatisfy(status.contains)
  }

  /// Settled once the daemon is idle and no window frame changed for 0.6 s.
  func settle(_ windows: some Collection<DesktopFixtureWindow>) -> Bool {
    var previous: [CGRect]?, since = Date()
    return pump({
      let frames = windows.map { (try? $0.frame()) ?? .null }
      if frames != previous { previous = frames; since = Date(); return false }
      return Date().timeIntervalSince(since) > 0.6 && self.settled()
    }, 8)
  }

  func workspaces() throws -> WorkspaceStateSnapshot {
    try JSONDecoder().decode(WorkspaceStateSnapshot.self, from: Data(run("list-workspaces --json").utf8))
  }

  func tiledWindowIDs() throws -> Set<UInt64> {
    Set(try workspaces().monitors.flatMap(\.workspaces).flatMap(\.windows).filter { $0.column != nil }.map(\.id))
  }

  func switchToEmptyWorkspace() throws -> String {
    let monitor = try XCTUnwrap(workspaces().monitors.first)
    let empty = try XCTUnwrap(monitor.workspaces.first { $0.windowCount == 0 }).id
    try run("workspace \(empty)")
    return empty
  }

  /// Column membership, top to bottom.
  func columns(_ workspace: String) throws -> [[UInt64]] {
    let windows = try XCTUnwrap(workspaces().monitors.flatMap(\.workspaces).first { $0.id == workspace }).windows
    let tiled = windows.filter { $0.column != nil }.sorted { ($0.column!, $0.row ?? 0) < ($1.column!, $1.row ?? 0) }
    return Dictionary(grouping: tiled) { $0.column! }.sorted { $0.key < $1.key }.map { $0.value.map(\.id) }
  }

  func converge(_ workspace: String, to expected: [[UInt64]]) -> Bool {
    converge(workspace) { $0 == expected }
  }

  func converge(_ workspace: String, _ condition: ([[UInt64]]) -> Bool) -> Bool {
    pump({ (try? self.columns(workspace)).map(condition) == true && self.settled() }, 5)
  }

  func diagnostics(_ workspace: String) -> String {
    "columns=\(String(describing: try? columns(workspace))) focused=\(String(describing: try? status("focused")))"
  }

  func trace() throws -> [(at: Double, event: String)] {
    try run("trace").split(separator: "\n").compactMap { line in
      let parts = line.split(separator: " ", maxSplits: 1)
      guard parts.count == 2, let at = Double(parts[0]) else { return nil }
      return (at, String(parts[1]))
    }
  }

  /// The trace keeps its last 512 entries, which a drag's frame burst rolls over in under a
  /// second: a recording polls it and fails if entries fell out between two reads.
  struct TraceRecording {
    fileprivate var last: Double
    private(set) var events: [String] = []

    fileprivate mutating func append(_ entries: [(at: Double, event: String)]) throws {
      if let first = entries.first, first.at > last {
        throw Failure("The daemon trace rolled over between two reads")
      }
      events += entries.filter { $0.at > last }.map(\.event)
      last = entries.last?.at ?? last
    }
  }

  func startRecording() throws -> TraceRecording {
    let entries = try trace()
    guard let last = entries.last?.at else { throw Failure("The daemon trace is empty") }
    return TraceRecording(last: last)
  }

  func record(_ recording: inout TraceRecording) throws { try recording.append(trace()) }

  /// A human-paced title-bar drag through the HID tap: down, 30 moves at about 20 ms, a 350 ms
  /// hold, then release. Returns the previews and membership while held, and the drops after.
  func drag(_ window: DesktopFixtureWindow, to target: CGPoint, workspace: String) throws
    -> (previews: [String], held: [[UInt64]], drops: [String], events: [String])
  {
    Thread.sleep(forTimeInterval: 0.5)
    let frame = try window.frame()
    let start = CGPoint(x: frame.midX, y: frame.minY + 12)
    // Away from the display edges, macOS's own window tiling never engages.
    let display = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 80, dy: 0)
    let end = CGPoint(x: min(max(target.x, display.minX), display.maxX), y: target.y)
    var recording = try startRecording()
    func post(_ type: CGEventType, _ point: CGPoint) {
      CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    }
    func wait(_ seconds: TimeInterval) throws {
      let deadline = Date().addingTimeInterval(seconds)
      repeat {
        Thread.sleep(forTimeInterval: 0.01)
        try record(&recording)
      } while Date() < deadline
    }
    post(.mouseMoved, start)
    try wait(0.08)
    post(.leftMouseDown, start)
    var released = false
    defer { if !released { post(.leftMouseUp, end) } }
    try wait(0.12)
    for step in 1...30 {
      let t = Double(step) / 30
      post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
      try wait(0.02)
    }
    try wait(0.35)
    let held = try columns(workspace)
    try record(&recording)
    let heldEvents = recording.events.count
    post(.leftMouseUp, end)
    released = true
    let drop = "mouse-drop window=\(window.windowID) target="
    let deadline = Date().addingTimeInterval(2)
    while !recording.events.contains(where: { $0.hasPrefix(drop) }), Date() < deadline { try wait(0.02) }
    // A second commit of the same release would follow within a few frames.
    try wait(0.3)
    let preview = "mouse-drop-preview window=\(window.windowID) target="
    let previews = recording.events.prefix(heldEvents).filter { $0.hasPrefix(preview) }
      .map { $0.dropFirst(preview.count).components(separatedBy: " edge-offset=")[0] }
    return (previews, held,
      recording.events.filter { $0.hasPrefix(drop) }.map { String($0.dropFirst(drop.count)) },
      recording.events.filter { !$0.hasPrefix("fresh-read") && !$0.hasPrefix("window-snapshot") })
  }

  /// Frame writes the coordinator applied to one window over `seconds`.
  func appliedWrites(to id: UInt64, over seconds: TimeInterval) throws -> Int {
    var recording = try startRecording()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
      try record(&recording)
    }
    let events = recording.events.map { $0.split(separator: " ") }
    func field(_ fields: [Substring], _ name: String) -> Substring? {
      fields.first { $0.hasPrefix(name + "=") }.map { $0.dropFirst(name.count + 1) }
    }
    let generations = Set(events.compactMap({ fields -> Substring? in
      guard fields.first == "submit", let windows = field(fields, "windows"),
        windows.drop(while: { $0 != "[" }).dropFirst().dropLast().split(separator: ",").contains("\(id)")
      else { return nil }
      return field(fields, "g")
    }))
    // Generation-wide totals: a batch that also moved another window can only over-count.
    return events.filter { ["complete", "abort", "stale-completion"].contains($0.first) && field($0, "g").map(generations.contains) == true }
      .compactMap { field($0, "applied").flatMap { Int($0) } }.reduce(0, +)
  }

  func logTail() -> String {
    let text = (try? String(contentsOf: directory.appending(path: "daemon.log"), encoding: .utf8)) ?? ""
    return String(text.suffix(2_000))
  }
}

/// One ClampFixture window in its own app, driven over its JSON-lines protocol.
@MainActor
final class DesktopFixtureWindow {
  private(set) var windowID: UInt64 = 0
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let replies = ReplyBuffer()
  private let directory: URL
  private let pump: (() -> Bool, TimeInterval) -> Bool
  private var sequence = 0

  init(binary: String, minimumHeight: Double?, refusesClose: Bool = false,
    pump: @escaping (() -> Bool, TimeInterval) -> Bool) throws {
    self.pump = pump
    let token = UUID().uuidString.lowercased()
    directory = FileManager.default.temporaryDirectory.appending(path: "DefiClampFixture-\(token)")
    let contents = directory.appending(path: "Fixture.app/Contents")
    let executable = contents.appending(path: "MacOS/ClampFixture")
    do {
      try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: URL(filePath: binary), to: executable)
      try PropertyListSerialization.data(fromPropertyList: [
        "CFBundleIdentifier": "com.qeude.defi.clamp-fixture.\(token)", "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "ClampFixture", "NSPrincipalClass": "NSApplication",
      ], format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
      process.executableURL = executable
      var environment = ProcessInfo.processInfo.environment
      environment["DEFI_FIXTURE_MIN"] = minimumHeight.map { "200,\(Int($0.rounded(.up)))" }
      environment["DEFI_FIXTURE_REFUSE_CLOSE"] = refusesClose ? "1" : nil
      process.environment = environment
      process.standardInput = input
      process.standardOutput = output
      output.fileHandleForReading.readabilityHandler = { [replies] handle in
        let data = handle.availableData
        replies.text.withLock { $0 += String(decoding: data, as: UTF8.self) }
      }
      try process.run()
      let created = try ask("create", id: "main")
      let windows = try XCTUnwrap(created["windows"] as? [[String: Any]])
      windowID = try XCTUnwrap(windows.first?["windowNumber"] as? UInt64)
    } catch {
      close()
      throw error
    }
  }

  /// The window frame in CoreGraphics coordinates, top-left origin.
  func frame() throws -> CGRect {
    let windows = try XCTUnwrap(try ask("report")["windows"] as? [[String: Any]])
    let frame = try XCTUnwrap(windows.first?["frame"] as? [Double])
    return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
  }

  /// The fixture is the active app and its window is key.
  func hasNativeFocus() throws -> Bool {
    let report = try ask("report")
    let windows = try XCTUnwrap(report["windows"] as? [[String: Any]])
    return report["active"] as? Bool == true && windows.first?["key"] as? Bool == true
  }

  func close() {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
    if !pump({ !self.process.isRunning }, 2), process.isRunning {
      process.terminate()
      if !pump({ !self.process.isRunning }, 2) { kill(process.processIdentifier, SIGKILL) }
    }
    if process.processIdentifier > 0 { process.waitUntilExit() }
    try? FileManager.default.removeItem(at: directory)
  }

  private func ask(_ command: String, id: String? = nil) throws -> [String: Any] {
    sequence += 1
    let seq = sequence
    var request: [String: Any] = ["seq": seq, "command": command]
    request["id"] = id
    input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request) + Data([10]))
    var reply: [String: Any]?
    guard pump({
      let lines = self.replies.text.withLock { $0 }.split(separator: "\n")
      reply = lines.lazy.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        .first { $0["seq"] as? Int == seq }
      return reply != nil || !self.process.isRunning
    }, 15), let reply else { throw DesktopDaemon.Failure("Fixture did not answer \(command)") }
    if let error = reply["error"] as? String, !error.isEmpty { throw DesktopDaemon.Failure("Fixture: \(error)") }
    return reply
  }
}

private final class ReplyBuffer: Sendable {
  let text = Mutex("")
}
