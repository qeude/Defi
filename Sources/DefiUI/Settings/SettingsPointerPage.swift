import AppKit
import DefiConfig
import DefiModel
import SwiftUI
import DefiMacOS

@MainActor
struct PointerSettingsView: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest
  @State private var gestureDemo = SettingsPointerDemo.swipe

  var body: some View {
    let input = model.config.input
    Form {
      Section("Pointer", symbol: "cursorarrow", color: .blue) {
        Toggle(isOn: boolBinding("input", "focus_follows_mouse", input.focusFollowsMouse)) {
          SettingsInfoLabel(SettingsOption.focusFollowsPointer.title,
            "Moving the pointer onto a window focuses it, without a click.")
        }
          .settingsSearchTarget(.focusFollowsPointer)
        if input.focusFollowsMouse || request.reveals(.pointerFocusDelay, .pointerFocusScroll) {
          SettingsNumberRow(
            title: SettingsOption.pointerFocusDelay.title,
            value: Double(input.focusFollowsMouseDelayMS),
            range: 0...1_000, step: 10, unit: "ms",
            info: "How long the pointer must rest on a window before it takes focus. 0 ms focuses at once.",
            onChange: { model.set(table: "input", key: "focus_follows_mouse_delay_ms", value: String(Int($0.rounded()))) }
          )
            .settingsSearchTarget(.pointerFocusDelay)
          SettingsNumberRow(
            title: SettingsOption.pointerFocusScroll.title,
            value: (input.focusFollowsMouseMaxScrollAmount ?? 0) * 100,
            range: 0...100, step: 1, unit: "%",
            info: "How far the strip may scroll to focus a window under the pointer, as a share of the screen width. 0 % focuses only windows already fully in view.",
            onChange: { model.set(table: "input", key: "focus_follows_mouse_max_scroll_amount", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.pointerFocusScroll)
        }
        Toggle(isOn: boolBinding("input", "mouse_follows_focus", input.mouseFollowsFocus)) {
          SettingsInfoLabel(SettingsOption.pointerFollowsFocus.title,
            "Moves the pointer to the center of a window you focus with the keyboard, unless it is already inside.")
        }
          .settingsSearchTarget(.pointerFollowsFocus)
      }
      Section("Trackpad", symbol: "hand.draw", color: .teal) {
        SettingsPointerDemoView(demo: gestureDemo, input: input)
        ScrollGestureSettings(model: model, request: request)
          .onHover { if $0 { gestureDemo = .swipe } }
        if input.scrollGestures || request.reveals(.scrollGestureSpeed, .scrollGestureSnap) {
          SettingsNumberRow(
            title: SettingsOption.scrollGestureSpeed.title,
            value: input.scrollGestureSpeed * 100,
            range: 25...400, step: 5, unit: "%",
            onChange: { model.set(table: "input", key: "scroll_gesture_speed", value: String($0 / 100)) }
          )
            .settingsSearchTarget(.scrollGestureSpeed)
            .onHover { if $0 { gestureDemo = .swipe } }
          Toggle(isOn: boolBinding("input", "scroll_gesture_snap", input.scrollGestureSnap)) {
            SettingsInfoLabel(SettingsOption.scrollGestureSnap.title, input.scrollGestureSnap
              ? "The strip lands on the nearest column."
              : "The strip stops where you let go. The column in the middle gets focus.")
          }
            .settingsSearchTarget(.scrollGestureSnap)
            .onHover { if $0 { gestureDemo = .swipe } }
        }
        OverviewGestureSettings(model: model)
          .onHover { if $0 { gestureDemo = .overview } }
        WindowTilingConflict()
      }
    }
    .formStyle(.settingsCards)
    .animation(.smooth(duration: 0.3), value: input.focusFollowsMouse)
    .animation(.smooth(duration: 0.3), value: input.scrollGestures)
    .modifier(SettingsRevealModifier(request: request))
  }

  private func boolBinding(_ table: String, _ key: String, _ value: Bool) -> Binding<Bool> {
    Binding(get: { value }, set: { model.set(table: table, key: key, value: $0 ? "true" : "false") })
  }
}

/// Which fingers swipe the strip, whether the modifier must be held, and what macOS
/// already does with those swipes.
@MainActor
struct ScrollGestureSettings: View {
  let model: DefiSettingsModel
  let request: SettingsRevealRequest

  var body: some View {
    let input = model.config.input
    let fingers = input.scrollGestureFingers
    let modifier = model.config.scrollGestureModifier
    let system = systemTrackpadSwipes(fingers: fingers)
    let overviewFingers = input.overviewGesture ? input.overviewGestureFingers : nil
    let activationBlocked = !input.scrollGestures && fingers == overviewFingers
    Group {
      Toggle(SettingsOption.scrollGestures.title, isOn: Binding(
        get: { input.scrollGestures },
        set: { model.setScrollGesturesEnabled($0) }
      ))
        .settingsSearchTarget(.scrollGestures)
        .disabled(activationBlocked)
      if activationBlocked {
        Text("The Overview uses this gesture. Choose a different number of fingers to enable scrolling.")
          .settingsNote()
      }
      if input.scrollGestures || activationBlocked || request.reveals(.scrollGestureFingers, .scrollGestureModifier) {
        details(input: input, fingers: fingers, modifier: modifier, system: system, overviewFingers: overviewFingers)
      }
    }
  }

  @ViewBuilder private func details(
    input: InputConfig, fingers: Int, modifier: String, system: (horizontal: Bool, vertical: Bool), overviewFingers: Int?
  ) -> some View {
      GestureFingersMenu(
        title: SettingsOption.scrollGestureFingers.title,
        choices: [(2, "Two"), (3, "Three"), (4, "Four")],
        selection: fingers, reservedFingers: overviewFingers, reservation: "used by the Overview",
        select: model.setScrollGestureFingers
      )
        .settingsSearchTarget(.scrollGestureFingers)
      Toggle(isOn: Binding(
        get: { modifier != "none" },
        set: { held in
          if held {
            model.reset(table: "input", key: "scroll_gesture_modifier")
          } else {
            model.set(table: "input", key: "scroll_gesture_modifier", value: tomlString("none"))
          }
        }
      )) {
        SettingsInfoLabel(SettingsOption.scrollGestureModifier.title, caption(fingers: fingers, modifier: modifier, system: system))
      }
        .settingsSearchTarget(.scrollGestureModifier)
        .disabled(!input.scrollGestures || fingers == 2)
      if let conflict = conflict(fingers: fingers, system: system) {
        HStack(alignment: .firstTextBaseline) {
          Label(conflict, systemImage: "exclamationmark.triangle")
            .font(.caption)
          Spacer()
          MoreGesturesButton()
        }
      }
  }

  private func caption(fingers: Int, modifier: String, system: (horizontal: Bool, vertical: Bool)) -> String {
    let hand = (fingers == 2 ? "Two" : fingers == 3 ? "Three" : "Four") + " fingers"
      + (modifier == "none" ? "" : " with \(modifier) held")
    // Only the directions macOS leaves to Defi.
    let axes = [system.horizontal ? nil : "left or right for columns",
      system.vertical ? nil : "up or down for workspaces"].compactMap { $0 }
    let wheel = modifier == "none" ? "" : " The mouse wheel works too."
    return axes.isEmpty ? wheel.trimmingCharacters(in: .whitespaces)
      : "\(hand): \(axes.joined(separator: ", ")).\(wheel)"
  }

  private func conflict(fingers: Int, system: (horizontal: Bool, vertical: Bool)) -> String? {
    let direction: String
    switch (system.horizontal, system.vertical) {
    case (true, true): direction = ""
    case (false, true): direction = " up or down"
    case (true, false): direction = " left or right"
    case (false, false): return nil
    }
    let count = fingers == 3 ? "three" : "four"
    return "macOS already uses \(count)-finger swipes\(direction). Change them in More Gestures to use them here."
  }
}

/// macOS tiling takes a window released where a title-bar drag drops it at an edge.
struct WindowTilingConflict: View {
  @State private var tiling = systemWindowTilingByEdgeDrag()

  var body: some View {
    Group {
      if let places = places {
        HStack(alignment: .firstTextBaseline) {
          Label("macOS also tiles a window you drag to \(places), then Defi puts it back. "
            + "Turn off its tiling in Desktop & Dock to drag there smoothly.", systemImage: "exclamationmark.triangle")
            .font(.caption)
          Spacer()
          Button("Desktop & Dock…") { openDesktopAndDockSettings() }
        }
      }
    }
    // Picks up a change made in System Settings on the way back.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      tiling = systemWindowTilingByEdgeDrag()
    }
  }

  private var places: String? {
    switch (tiling.sides, tiling.top) {
    case (true, true): "a screen edge or the menu bar"
    case (true, false): "a screen's side edge"
    case (false, true): "the menu bar"
    case (false, false): nil
    }
  }
}

/// Opens the More Gestures tab of the Trackpad settings, where macOS assigns swipes.
struct MoreGesturesButton: View {
  var body: some View {
    Button("More Gestures…") {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension?MoreGestures")!)
    }
  }
}

/// Which fingers swipe the Overview open, and what keeps that swipe from working.
@MainActor
struct OverviewGestureSettings: View {
  let model: DefiSettingsModel

  var body: some View {
    let input = model.config.input
    let scrollFingers = input.scrollGestures ? input.scrollGestureFingers : nil
    GestureFingersMenu(
      title: SettingsOption.overviewGesture.title,
      choices: [(0, "Off"), (3, "Three fingers"), (4, "Four fingers")],
      selection: input.overviewGesture ? input.overviewGestureFingers : 0,
      reservedFingers: scrollFingers, reservation: "used by scrolling",
      select: { model.setOverviewGestureFingers($0 == 0 ? nil : $0) }
    )
      .settingsSearchTarget(.overviewGesture)
    if input.overviewGesture, input.overviewSwipesMoveStrip || systemTrackpadSwipes(fingers: input.overviewGestureFingers).vertical {
      caption(input)
    }
  }

  @ViewBuilder
  private func caption(_ input: InputConfig) -> some View {
    let count = input.overviewGestureFingers == 3 ? "Three" : "Four"
    if input.overviewSwipesMoveStrip {
      Label("\(count)-finger swipes move the strip. Choose another number of fingers for one of them.",
        systemImage: "exclamationmark.triangle")
        .font(.caption)
    } else if systemTrackpadSwipes(fingers: input.overviewGestureFingers).vertical {
      HStack(alignment: .firstTextBaseline) {
        Label("macOS already uses \(count.lowercased())-finger swipes up and down. Set Mission Control's gesture to Off or another number of fingers in More Gestures; Mission Control stays on its key.",
          systemImage: "exclamationmark.triangle")
          .font(.caption)
        Spacer()
        MoreGesturesButton()
      }
    }
  }
}

struct GestureFingersMenu: View {
  let title: String
  let choices: [(fingers: Int, title: String)]
  let selection: Int
  let reservedFingers: Int?
  let reservation: String
  let select: (Int) -> Void

  var body: some View {
    let selectedTitle = choices.first { $0.fingers == selection }?.title ?? ""
    LabeledContent(title) {
      // A macOS menu-style Picker ignores disabled modifiers on individual choices.
      Menu {
        ForEach(choices, id: \.fingers) { choice in
          let label = choice.fingers == reservedFingers ? "\(choice.title) · \(reservation)" : choice.title
          Button {
            select(choice.fingers)
          } label: {
            if choice.fingers == selection {
              Label(label, systemImage: "checkmark")
            } else {
              Text(label)
            }
          }
          .disabled(choice.fingers == reservedFingers)
        }
      } label: {
        Text(selectedTitle)
      }
      .accessibilityLabel(title)
      .accessibilityValue(selectedTitle)
    }
  }
}
