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
    let floatingWindowID = WindowID(rawValue: 8)
    let monitors = [
      Monitor(
        id: firstMonitor,
        workspaces: [
          Workspace(id: dev, floatingWindows: [floatingWindowID], focusedLayer: .floating)
        ],
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
      ),
      floatingWindowID: Window(
        id: floatingWindowID,
        appID: "com.apple.finder",
        title: "Files",
        frame: Rect(x: 0, y: 0, width: 800, height: 600),
        floating: true
      ),
    ]

    let snapshot = makeWorkspaceStateSnapshot(
      monitors: monitors,
      windows: windows,
      displayOrder: [secondMonitor, firstMonitor],
      focusedMonitorID: secondMonitor,
      workspaceIcons: ["web": "globe"]
    )

    #expect(snapshot.monitors.map(\.id) == [20, 10])
    #expect(snapshot.monitors.map(\.display) == [1, 2])
    #expect(snapshot.monitors[0].focused)
    let webSnapshot = try #require(
      snapshot.monitors[0].workspaces.first(where: { $0.name == "web" })
    )
    #expect(webSnapshot.active)
    #expect(webSnapshot.id == "web")
    #expect(webSnapshot.position == 2)
    #expect(webSnapshot.kind == .named)
    #expect(webSnapshot.occupied)
    #expect(webSnapshot.windowCount == 1)
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
    #expect(encodedWeb["icon"] as? String == "globe")
    #expect(encodedWeb["selectedWindowID"] as? UInt64 == 7)
    let tiled = try #require((encodedWeb["windows"] as? [[String: Any]])?.first)
    #expect(tiled["id"] as? UInt64 == 7)
    #expect(tiled["appID"] as? String == "com.apple.Safari")
    #expect(tiled["title"] as? String == "Web")
    #expect(tiled["column"] as? Int == 1)
    #expect(tiled["row"] as? Int == 1)
    #expect(tiled["floating"] as? Bool == false)
    #expect(tiled["selected"] as? Bool == true)

    let otherWorkspace = try #require(
      (encodedMonitors[1]["workspaces"] as? [[String: Any]])?.first
    )
    #expect(otherWorkspace["selectedWindowID"] as? UInt64 == 8)
    let floating = try #require((otherWorkspace["windows"] as? [[String: Any]])?.first)
    #expect(floating["floating"] as? Bool == true)
    #expect(floating["selected"] as? Bool == true)
    #expect(floating["column"] == nil)
    #expect(floating["row"] == nil)

    let encodedDev = try #require(
      encodedWorkspaces.first(where: { $0["name"] as? String == "dev" })
    )
    #expect(encodedDev["icon"] == nil)
    #expect(encodedDev["selectedWindowID"] == nil)
    #expect((encodedDev["windows"] as? [[String: Any]])?.isEmpty == true)
  }

}
