import Testing
import AppKit
import DefiConfig
import class SwiftUI.NSHostingMenu

@testable import DefiMacOS

@MainActor
struct MenuBarTests {
  @Test
  func swiftUIMenuKeepsWorkspaceSelectionAndCommandRouting() throws {
    _ = NSApplication.shared
    var commands: [String] = []
    let state = MenuBarState(accessibilityTrusted: { true })
    state.update(monitors: [MenuMonitor(id: 1, isFocused: true, activeWorkspace: "dev",
      workspaces: [MenuWorkspace(id: "dev", label: "Dev"), MenuWorkspace(id: "web", label: "Web")])])
    let menu = NSHostingMenu(rootView: MenuBarContent(state: state, commandHandler: { commands.append($0) }))
    menu.update()
    #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["Workspaces", "Settings…", "-", "Support Defi…", "-", "Quit Defi"])
    #expect(menu.items.allSatisfy { $0.image == nil })
    let settings = try #require(menu.items.first { $0.title == "Settings…" })
    #expect(settings.keyEquivalent == ",")
    #expect(settings.keyEquivalentModifierMask == .command)
    let workspaces = try #require(menu.items.first { $0.title == "Workspaces" }?.submenu)
    workspaces.update()
    #expect(workspaces.items.first { $0.title == "Dev" }?.state == .on)
    workspaces.performActionForItem(at: try #require(workspaces.items.firstIndex { $0.title == "Web" }))
    menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Quit Defi" }))
    let deadline = Date().addingTimeInterval(1)
    while commands.count < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    #expect(commands == ["workspace web", "quit"])
  }

  @Test
  func stripShowsEveryDisplayAndHitsTheClickedWorkspace() throws {
    let state = MenuBarState(accessibilityTrusted: { true })
    let left = MenuMonitor(id: 1, isFocused: false, activeWorkspace: "1",
      workspaces: [MenuWorkspace(id: "1", label: "1"), MenuWorkspace(id: "2", label: "2", isEmpty: true)])
    let right = MenuMonitor(id: 2, isFocused: true, activeWorkspace: "web",
      workspaces: [MenuWorkspace(id: "dev", label: "dev", icon: "terminal", position: 1),
        MenuWorkspace(id: "web", label: "web", icon: "not.a.real.defi.symbol", position: 2),
        MenuWorkspace(id: "3", label: "3", position: 3, isEmpty: true)])
    state.update(monitors: [left, right])
    #expect(state.activeLabel == "web")
    #expect(state.workspaces.map(\.id) == ["dev", "web", "3"])

    let dots = menuBarLayout(state.displayedMonitors, config: state.config)
    #expect(dots.marks.map(\.workspaceID) == ["1", "2", "dev", "web", "3"])
    #expect(dots.dividers.count == 1)
    let web = try #require(dots.marks.first { $0.workspaceID == "web" })
    let dev = try #require(dots.marks.first { $0.workspaceID == "dev" })
    #expect(web.knockout && web.rect.width > dev.rect.width && dev.contentAlpha == 0)
    // An empty workspace is a ring, an occupied one a dot, and the unfocused display is dimmer.
    let empty = try #require(dots.marks.first { $0.workspaceID == "3" })
    #expect(empty.fill == 0 && empty.stroke > 0 && dev.fill > 0 && dev.stroke == 0)
    #expect(dots.marks[0].fill < 1 && dots.marks[0].knockout)
    for mark in dots.marks {
      #expect(dots.workspace(atX: mark.rect.midX) == mark.workspaceID)
    }
    // A click inside a wide mark wins over a nearer dot's looser tap area.
    #expect(dots.workspace(atX: web.rect.minX + 1) == "web")
    #expect(dots.workspace(atX: dots.size.width + 20) == nil)

    state.update(monitors: [left, right], config: MenuBarConfig(workspaceStyle: .icon, indicator: .pill, show: .current))
    let pills = menuBarLayout(state.displayedMonitors, config: state.config)
    #expect(pills.marks.map(\.workspaceID) == ["dev", "web", "3"] && pills.dividers.isEmpty)
    #expect(pills.marks.allSatisfy { $0.rect.height > 6 && $0.contentAlpha > 0 })
    #expect(pills.marks.map(\.label) == [nil, nil, "3"])
    #expect(menuBarSymbol("not.a.real.defi.symbol") != nil)
    #expect(menuBarImage(pills).isTemplate)

    let circles = menuBarLayout(state.displayedMonitors, config: MenuBarConfig(indicator: .circle, show: .current))
    #expect(circles.marks.map(\.label) == ["1", "2", "3"])
    #expect(circles.marks.allSatisfy { $0.rect.width == $0.rect.height && $0.icon == nil })
    let iconCircles = menuBarLayout(state.displayedMonitors,
      config: MenuBarConfig(workspaceStyle: .iconAndName, indicator: .circle, show: .current))
    #expect(iconCircles.marks.map(\.label) == [nil, nil, "3"] && iconCircles.marks[0].icon == "terminal")
    let boxes = menuBarLayout(state.displayedMonitors,
      config: MenuBarConfig(indicator: .box, inactiveStyle: .outlined, equalWidth: true, show: .current))
    #expect(Set(boxes.marks.map(\.rect.width)).count == 1 && boxes.marks[0].radius < boxes.marks[0].rect.height / 2)
    #expect(boxes.marks[0].stroke > 0 && !boxes.marks[0].knockout && boxes.marks[1].knockout)
    state.update(monitors: [left, right], config: MenuBarConfig(show: .active))
    let active = menuBarLayout(state.displayedMonitors, config: state.config)
    #expect(active.marks.map(\.workspaceID) == ["web"] && active.marks[0].knockout && active.dividers.isEmpty)
    let blank = menuBarLayout(state.displayedMonitors, config: MenuBarConfig(workspaceStyle: .none, indicator: .box, show: .current))
    #expect(blank.marks.allSatisfy { $0.label == nil && $0.icon == nil })
  }

  @Test
  func idleDisplaysAndMissingDisplaysStayReadable() {
    let state = MenuBarState(accessibilityTrusted: { true })
    let busy = MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: [MenuWorkspace(id: "1", label: "1")])
    let idle = MenuMonitor(id: 2, isFocused: false, activeWorkspace: "2",
      workspaces: [MenuWorkspace(id: "2", label: "1", isEmpty: true)])
    state.update(monitors: [busy, idle])
    #expect(state.displayedMonitors.map(\.id) == [1])
    state.update(monitors: [MenuMonitor(id: 1, isFocused: false, activeWorkspace: "1",
      workspaces: [MenuWorkspace(id: "1", label: "1", isEmpty: true)]), MenuMonitor(id: 2, isFocused: true,
      activeWorkspace: "2", workspaces: [MenuWorkspace(id: "2", label: "1", isEmpty: true)])])
    #expect(state.displayedMonitors.map(\.id) == [2])
    // Before Accessibility is granted the daemon knows no display; the item must not shrink to nothing.
    #expect(menuBarImage(menuBarLayout([], config: MenuBarConfig())).size.width >= 10)
  }

  @Test
  func animationMorphsMarksBetweenLayouts() {
    let config = MenuBarConfig()
    let workspaces = [MenuWorkspace(id: "1", label: "1"), MenuWorkspace(id: "2", label: "2")]
    let from = menuBarLayout([MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: workspaces)], config: config)
    let to = menuBarLayout([MenuMonitor(id: 1, isFocused: true, activeWorkspace: "2", workspaces: workspaces)], config: config)
    #expect(interpolate(from, to, 0) == from)
    #expect(interpolate(from, to, 1) == to)
    let middle = interpolate(from, to, 0.5)
    #expect(middle.marks[1].rect.width > to.marks[0].rect.width && middle.marks[1].rect.width < to.marks[1].rect.width)

    // A renamed workspace fades its old label out before the new one fades in, never both at full strength.
    let renamed = menuBarLayout([MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1",
      workspaces: [MenuWorkspace(id: "1", label: "web"), workspaces[1]])], config: config)
    let early = interpolate(from, renamed, 0.1).marks[0]
    #expect(early.outgoing?.label == "1" && early.outgoing!.alpha > 0 && early.contentAlpha == 0)
    let late = interpolate(from, renamed, 0.9).marks[0]
    #expect(late.label == "web" && late.outgoing?.alpha == 0 && late.contentAlpha > 0)
  }

  @Test
  func refreshesAccessibilityPermissionWhenMenuOpens() {
    var trusted = false
    let state = MenuBarState(accessibilityTrusted: { trusted })
    #expect(state.needsAccessibilityPermission)

    trusted = true
    state.refreshAccessibilityPermission()
    #expect(!state.needsAccessibilityPermission)

    trusted = false
    state.refreshAccessibilityPermission()
    #expect(state.needsAccessibilityPermission)
  }


  @Test
  func columnsItemFramesTheColumnsOnScreenAndHitsTheClickedOne() throws {
    // A 1000-point strip scrolled one column right: column 1 (focused) and 2 are on screen.
    let columns = [MenuColumn(x: -500, width: 500, windows: 1, windowID: 10),
      MenuColumn(x: 0, width: 500, windows: 1, windowID: 11),
      MenuColumn(x: 500, width: 500, windows: 2, windowID: 12),
      MenuColumn(x: 1000, width: 330, windows: 1, windowID: 13)]
    let monitor = MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: [],
      columns: columns, focusedColumn: 1, stripWidth: 1000)
    let layout = menuBarColumnsLayout(monitor, maxWidth: 60)
    #expect(layout.bars.map(\.alpha) == [0.28, 1, 0.55, 0.28])
    #expect(layout.frame.minX < layout.bars[1].rect.minX && layout.bars[2].rect.maxX < layout.frame.maxX)
    #expect(layout.frame.maxX < layout.bars[3].rect.minX && layout.bars[0].rect.maxX < layout.frame.minX)
    for bar in layout.bars { #expect(layout.windowID(atX: bar.rect.midX) == bar.windowID) }
    // A click near the edge of a wide bar stays on it, even when a narrow neighbor's middle is closer.
    let edge = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: [],
      columns: [MenuColumn(x: 0, width: 2000, windows: 1, windowID: 1), MenuColumn(x: 2000, width: 100, windows: 1, windowID: 2)],
      focusedColumn: 0, stripWidth: 1000), maxWidth: 60)
    #expect(edge.windowID(atX: edge.bars[0].rect.maxX - 0.5) == 1)

    // A column half off the left edge: the frame starts in its middle, not at the focused one.
    let partial = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: [],
      columns: [MenuColumn(x: -250, width: 500, windows: 1, windowID: 1), MenuColumn(x: 250, width: 750, windows: 1, windowID: 2)],
      focusedColumn: 1, stripWidth: 1000), maxWidth: 60)
    #expect(abs(partial.frame.minX - (partial.bars[0].rect.midX - 1.5)) < 0.01)
    #expect(abs(partial.frame.maxX - (partial.bars[1].rect.maxX + 1.5)) < 0.01)

    // Scrolling slides the frame over the bars; a new column fades in.
    let scrolled = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1", workspaces: [],
      columns: columns.map { MenuColumn(x: $0.x - 500, width: $0.width, windows: $0.windows, windowID: $0.windowID) }
        + [MenuColumn(x: 830, width: 300, windows: 1, windowID: 14)],
      focusedColumn: 2, stripWidth: 1000), maxWidth: 60)
    #expect(interpolate(layout, scrolled, 0) == layout && interpolate(layout, scrolled, 1) == scrolled)
    let halfway = interpolate(layout, scrolled, 0.5)
    #expect(abs(halfway.frame.minX - (layout.frame.minX + scrolled.frame.minX) / 2) < 0.01)
    #expect(halfway.bars[4].alpha == scrolled.bars[4].alpha / 2)

    let many = (0..<40).map { MenuColumn(x: Double($0) * 500, width: 500, windows: 1, windowID: UInt64($0)) }
    let crowded = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1",
      workspaces: [], columns: Array(many.prefix(12)), focusedColumn: 0, stripWidth: 1000), maxWidth: 60)
    #expect(crowded.size.width <= 60)
    let wide = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1",
      workspaces: [], columns: Array(many.prefix(12)), focusedColumn: 0, stripWidth: 1000), maxWidth: 120)
    #expect(wide.size.width > crowded.size.width && wide.size.width <= 120)
    let packed = menuBarColumnsLayout(MenuMonitor(id: 1, isFocused: true, activeWorkspace: "1",
      workspaces: [], columns: many, focusedColumn: 0, stripWidth: 1000), maxWidth: 60)
    #expect(packed.bars.allSatisfy { $0.rect.width >= 2 })
    #expect(menuBarColumnsLayout(nil, maxWidth: 60).bars.isEmpty)
  }
}
