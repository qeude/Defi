import DefiIPC
import DefiModel
import Foundation
import Testing

struct WorkspaceStateTests {
  @Test
  func snapshotPreservesDisplayOrderAndWorkspaceContents() throws {
    let firstMonitor = MonitorID(rawValue: 10)
    let secondMonitor = MonitorID(rawValue: 20)
    let dev = WorkspaceID(rawValue: "dev")
    let web = WorkspaceID(rawValue: "web")
    let windowID = WindowID(rawValue: 7)
    let monitors = [
      Monitor(
        id: firstMonitor,
        workspaces: [Workspace(id: dev)],
        activeWorkspace: dev
      ),
      Monitor(
        id: secondMonitor,
        workspaces: [
          Workspace(id: dev),
          Workspace(
            id: web,
            columns: [
              Column(window: windowID, width: .fraction(0.8))
            ]),
        ],
        activeWorkspace: web
      ),
    ]
    let windows = [
      windowID: Window(
        id: windowID,
        appID: "com.apple.Safari",
        title: "Web",
        frame: Rect(x: 0, y: 0, width: 800, height: 600)
      )
    ]

    let snapshot = makeWorkspaceStateSnapshot(
      monitors: monitors,
      windows: windows,
      displayOrder: [secondMonitor, firstMonitor],
      focusedMonitorID: secondMonitor
    )

    #expect(snapshot.version == 1)
    #expect(snapshot.monitors.map(\.id) == [20, 10])
    #expect(snapshot.monitors.map(\.display) == [1, 2])
    #expect(snapshot.monitors[0].focused)
    let webSnapshot = try #require(
      snapshot.monitors[0].workspaces.first(where: { $0.name == "web" })
    )
    #expect(webSnapshot.active)
    #expect(webSnapshot.occupied)
    #expect(webSnapshot.windowCount == 1)
    #expect(webSnapshot.occupied)
    #expect(webSnapshot.applications == ["com.apple.Safari"])
    #expect(webSnapshot.focusedApplication == "com.apple.Safari")

    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
    let root = try #require(json as? [String: Any])
    let encodedMonitors = try #require(root["monitors"] as? [[String: Any]])
    let encodedWorkspaces = try #require(
      encodedMonitors[0]["workspaces"] as? [[String: Any]]
    )
    let encodedWeb = try #require(
      encodedWorkspaces.first(where: { $0["name"] as? String == "web" })
    )
    #expect(encodedWeb["occupied"] as? Bool == true)
  }

  @Test
  func requestRoundTripPreservesMonitorTarget() throws {
    let request = CommandRequest(command: "workspace web", monitorIndex: 2)
    let data = try JSONEncoder().encode(request)

    #expect(try JSONDecoder().decode(CommandRequest.self, from: data) == request)
  }

  @Test
  func requestWithoutMonitorRemainsBackwardCompatible() throws {
    let data = Data(#"{"command":"workspace dev"}"#.utf8)

    let request = try JSONDecoder().decode(CommandRequest.self, from: data)

    #expect(request.command == "workspace dev")
    #expect(request.monitorIndex == nil)
  }
}
