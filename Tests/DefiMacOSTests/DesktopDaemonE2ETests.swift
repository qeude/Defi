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

  func testModifierDragMovesAndResizesFromAnywhere() throws {
    let lane = try daemonLane()
    let daemon = try lane.startDaemon(config: "[layout]\ndefault_column_width = 0.3\n")
    defer { daemon.stop() }
    var windows: [UInt64: DesktopFixtureWindow] = [:]
    defer { windows.values.forEach { $0.close() } }
    let workspace = try daemon.switchToEmptyWorkspace()
    for _ in 0..<3 {
      let window = try lane.openWindow(minimumHeight: nil, daemon: daemon)
      windows[window.windowID] = window
    }
    let ids = try daemon.columns(workspace).joined().map { $0 }
    XCTAssertEqual(ids.count, 3, daemon.diagnostics(workspace))
    let (a, b, c) = (ids[0], ids[1], ids[2])
    func frame(_ id: UInt64) throws -> CGRect { try XCTUnwrap(windows[id]).frame() }
    // The default `mod`.
    let mod: CGEventFlags = [.maskControl, .maskAlternate]

    // From the middle of the window, far from its title bar.
    let moved = try daemon.drag(try XCTUnwrap(windows[c]), from: CGPoint(x: try frame(c).midX, y: try frame(c).midY),
      to: CGPoint(x: try frame(a).minX + 0.15 * frame(a).width, y: try frame(c).midY), flags: mod, workspace: workspace)
    XCTAssertEqual(moved.held, [[a], [b], [c]], "Membership must not change while the button is held")
    XCTAssertEqual(moved.previews.last, "column(index: 0)", "previews: \(moved.previews)")
    XCTAssertEqual(moved.drops, ["column(index: 0)"], "Release must commit the previewed target once")
    XCTAssertTrue(daemon.converge(workspace, to: [[c], [a], [b]]),
      daemon.diagnostics(workspace) + "\n" + moved.events.suffix(40).joined(separator: "\n"))
    XCTAssertTrue(daemon.settle(windows.values))
    XCTAssertEqual(try daemon.status("focused"), "\(c)", "The dropped window takes focus")

    // A right drag near the right edge widens the column by the pointer's travel.
    let before = try frame(a)
    let resized = try daemon.drag(try XCTUnwrap(windows[a]), from: CGPoint(x: before.maxX - 20, y: before.midY),
      to: CGPoint(x: before.maxX + 100, y: before.midY), button: .right, flags: mod, workspace: workspace)
    XCTAssertEqual(resized.held, [[c], [a], [b]])
    XCTAssertTrue(resized.drops.isEmpty, "A resize drops nothing: \(resized.drops)")
    XCTAssertTrue(daemon.settle(windows.values))
    let after = try frame(a)
    XCTAssertEqual(after.width - before.width, 120, accuracy: 4, "The column must widen by the drag: \(before) → \(after)")
    XCTAssertEqual(after.minX, before.minX, accuracy: 2, "The left edge stays")
    XCTAssertEqual(try daemon.columns(workspace), [[c], [a], [b]])
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
  func openWindow(minimumHeight: Double?, daemon: DesktopDaemon) throws -> DesktopFixtureWindow {
    let window = try DesktopFixtureWindow(binary: fixtureBinary, minimumHeight: minimumHeight, pump: pump)
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
  /// Drags by the title bar, or from `start` with `flags` held (a modifier drag).
  func drag(_ window: DesktopFixtureWindow, from start: CGPoint? = nil, to target: CGPoint,
    button: CGMouseButton = .left, flags: CGEventFlags = [], workspace: String) throws
    -> (previews: [String], held: [[UInt64]], drops: [String], events: [String])
  {
    Thread.sleep(forTimeInterval: 0.5)
    let frame = try window.frame()
    let start = start ?? CGPoint(x: frame.midX, y: frame.minY + 12)
    let (down, dragged, up): (CGEventType, CGEventType, CGEventType) = button == .right
      ? (.rightMouseDown, .rightMouseDragged, .rightMouseUp) : (.leftMouseDown, .leftMouseDragged, .leftMouseUp)
    // Away from the display edges, macOS's own window tiling never engages.
    let display = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 80, dy: 0)
    let end = CGPoint(x: min(max(target.x, display.minX), display.maxX), y: target.y)
    var recording = try startRecording()
    func post(_ type: CGEventType, _ point: CGPoint) {
      let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
      if type != .mouseMoved { event?.flags = flags }
      event?.post(tap: .cghidEventTap)
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
    post(down, start)
    var released = false
    defer { if !released { post(up, end) } }
    try wait(0.12)
    for step in 1...30 {
      let t = Double(step) / 30
      post(dragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
      try wait(0.02)
    }
    try wait(0.35)
    let held = try columns(workspace)
    try record(&recording)
    let heldEvents = recording.events.count
    post(up, end)
    released = true
    let drop = "mouse-drop window=\(window.windowID) target="
    let ended = "window-drag-ended window=\(window.windowID) "
    let deadline = Date().addingTimeInterval(2)
    while !recording.events.contains(where: { $0.hasPrefix(drop) || $0.hasPrefix(ended) }), Date() < deadline {
      try wait(0.02)
    }
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

  init(binary: String, minimumHeight: Double?, pump: @escaping (() -> Bool, TimeInterval) -> Bool) throws {
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
