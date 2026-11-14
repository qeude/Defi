import Darwin
import DefiModel
import Foundation
import Testing

@testable import DefiIPC

struct EventStreamTests {
  private let monitorID = MonitorID(rawValue: 1)
  private let dev = WorkspaceID(rawValue: "dev")
  private let web = WorkspaceID(rawValue: "web")

  private func window(_ id: UInt64, _ title: String = "Window") -> Window {
    Window(
      id: WindowID(rawValue: id), appID: "com.example.app", title: title,
      frame: Rect(x: 0, y: 0, width: 800, height: 600)
    )
  }

  /// `dev` holds columns [1, 2] then [3], `web` holds floating window 4.
  private func makeState(
    active: WorkspaceID? = nil,
    focusedColumn: Int = 0,
    devColumns: [[UInt64]] = [[1, 2], [3]],
    titles: [UInt64: String] = [:]
  ) -> EventStreamState {
    var devWorkspace = Workspace(
      id: dev,
      columns: devColumns.map {
        Column(windows: $0.map { WindowID(rawValue: $0) }, focusedWindow: 0, width: .fraction(0.5))
      }
    )
    devWorkspace.focusedColumn = focusedColumn
    var webWorkspace = Workspace(id: web)
    webWorkspace.floatingWindows = [WindowID(rawValue: 4)]
    let monitor = Monitor(
      id: monitorID, workspaces: [devWorkspace, webWorkspace], activeWorkspace: active ?? dev
    )
    let ids: [UInt64] = devColumns.flatMap { $0 } + [4]
    let windows = Dictionary(uniqueKeysWithValues: ids.map {
      (WindowID(rawValue: $0), window($0, titles[$0] ?? "Window"))
    })
    let workspaces = makeWorkspaceStateSnapshot(
      monitors: [monitor], windows: windows, displayOrder: [monitorID], focusedMonitorID: monitorID
    )
    let list = makeWindowListSnapshot(
      monitors: [monitor], windows: windows, displayOrder: [monitorID],
      focusedMonitorID: monitorID, appName: { _ in "Example" }
    )
    return EventStreamState(workspaces: workspaces, windows: list.windows)
  }

  @Test
  func `Window list reports placement and focus`() {
    let state = makeState()
    let windows = state.windows
    #expect(windows.map(\.id) == [1, 2, 3, 4])
    #expect(windows.map(\.column) == [1, 1, 2, nil])
    #expect(windows.map(\.row) == [1, 2, 1, nil])
    #expect(windows.map(\.floating) == [false, false, false, true])
    #expect(windows.map(\.focused) == [true, false, false, false])
    #expect(windows[3].workspace == .init(id: "web", name: "web", position: 2))
    #expect(windows[0].appName == "Example")
    #expect(windows[0].display == 1)

    let workspaces = state.workspaces.monitors[0].workspaces
    #expect(workspaces[0].windows?.map(\.column) == [1, 1, 2])
    #expect(workspaces[0].windows?.map(\.row) == [1, 2, 1])
    #expect(workspaces[0].windows?.map(\.selected) == [true, false, false])
    #expect(workspaces[1].selectedWindowID == nil)
    #expect(workspaces[1].windows?.map(\.selected) == [false])
  }

  @Test
  func `Diff reports opened, closed, moved, retitled windows and focus`() {
    let old = makeState()
    let new = makeState(focusedColumn: 1, devColumns: [[2, 5], [3]], titles: [3: "Renamed"])

    let events = streamEvents(from: old, to: new)

    #expect(events.map(\.event) == [
      "workspaces-changed", "window-closed", "window-moved", "window-opened",
      "window-changed", "focus-changed",
    ])
    #expect(events[1].windowID == 1)
    #expect(events[2].window?.id == 2)
    #expect(events[3].window?.id == 5)
    #expect(events[4].window?.title == "Renamed")
    #expect(events[5].windowID == 3)
  }

  @Test
  func `Diff reports windows whose workspace position changed as moved`() {
    let old = makeState()
    let reordered = old.windows.map { window in
      WindowSnapshot(
        id: window.id, appID: window.appID, appName: window.appName, title: window.title,
        workspace: .init(id: window.workspace.id, name: window.workspace.name,
          position: window.workspace.position + 1),
        monitorID: window.monitorID, display: window.display + 1,
        column: window.column, row: window.row, floating: window.floating,
        focused: window.focused
      )
    }

    let events = streamEvents(from: old, to: EventStreamState(workspaces: old.workspaces, windows: reordered))

    #expect(events.map(\.event) == Array(repeating: "window-moved", count: 4))
  }

  @Test
  func `Diff reports workspace activation once per display`() {
    let events = streamEvents(from: makeState(), to: makeState(active: web))

    let activation = events.filter { $0.event == "workspace-activated" }
    #expect(activation.count == 1)
    #expect(activation.first?.workspace?.id == "web")
    #expect(activation.first?.monitorID == 1)
    #expect(events.last?.event == "focus-changed")
    #expect(events.last?.window == nil)
    #expect(streamEvents(from: makeState(), to: makeState()).isEmpty)
  }

  @Test
  func `Subscriber receives a snapshot then coalesced changes`() throws {
    let (server, client) = try socketPair()
    defer { Darwin.close(client) }
    let hub = EventStreamHub(coalescingInterval: .milliseconds(5))
    hub.publish(makeState())
    hub.subscribe(server)

    let snapshot = try readEvents(from: client, count: 1)
    #expect(snapshot.map(\.event) == ["snapshot"])
    #expect(snapshot.first?.windows?.count == 4)
    #expect(snapshot.first?.version == 1)

    // Two quick changes reach the subscriber as one diff from the snapshot.
    hub.publish(makeState(focusedColumn: 1))
    hub.publish(makeState(focusedColumn: 1, titles: [3: "Renamed"]))
    let events = try readEvents(from: client, count: 3)
    #expect(events.map(\.event) == ["workspaces-changed", "window-changed", "focus-changed"])
  }

  @Test
  func `Subscriber joining during a pending change still starts with its snapshot`() throws {
    let (firstServer, first) = try socketPair()
    let (secondServer, second) = try socketPair()
    defer { Darwin.close(first); Darwin.close(second) }
    let hub = EventStreamHub(coalescingInterval: .seconds(5))
    hub.publish(makeState())
    hub.subscribe(firstServer)
    _ = try readEvents(from: first, count: 1)

    hub.publish(makeState(focusedColumn: 1))
    hub.subscribe(secondServer)

    let joined = try readEvents(from: second, count: 1)
    #expect(joined.map(\.event) == ["snapshot"])
    #expect(joined.first?.windows?.first(where: \.focused)?.id == 3)
    let events = try readEvents(from: first, count: 2)
    #expect(events.map(\.event) == ["workspaces-changed", "focus-changed"])
  }

  @Test
  func `Subscriber that falls behind is disconnected`() throws {
    let (server, client) = try socketPair()
    defer { Darwin.close(client) }
    let hub = EventStreamHub(maximumPendingBytes: 64)
    hub.publish(makeState())
    hub.subscribe(server)

    var byte: UInt8 = 0
    #expect(Darwin.read(client, &byte, 1) == 0)
    #expect(hub.clientCount == 0)
  }

  private func socketPair() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    try configureNoSigPipe(descriptors[0])
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptors[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return (descriptors[0], descriptors[1])
  }

  private func readEvents(from descriptor: Int32, count: Int) throws -> [StreamEvent] {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while data.filter({ $0 == 0x0A }).count < count {
      let read = Darwin.read(descriptor, &buffer, buffer.count)
      try #require(read > 0)
      data.append(contentsOf: buffer[..<read])
    }
    return try data.split(separator: 0x0A).map {
      try JSONDecoder().decode(StreamEvent.self, from: Data($0))
    }
  }
}
