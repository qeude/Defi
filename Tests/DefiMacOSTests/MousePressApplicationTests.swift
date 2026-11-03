import DefiCore
import DefiModel
import Testing

@testable import DefiMacOS

struct MousePressApplicationTests {
  private let frame = Rect(x: 0, y: 0, width: 100, height: 100)
  private var windows: [CGWindowRecord] {
    [
      CGWindowRecord(id: 7, processID: 99, layer: 20, title: "Dock", frame: frame, isOnscreen: true),
      CGWindowRecord(id: 8, processID: 10, layer: 0, title: "sheet", frame: frame, isOnscreen: true),
    ]
  }

  @Test
  func `Dock press is outside the focused application`() {
    #expect(mousePressLandedInOtherApplication(pressedWindowID: WindowID(rawValue: 7),
      pressedWindowIsManaged: false, focusedProcessID: 10, windows: windows))
  }

  @Test
  func `Press on the focused application keeps its gesture`() {
    #expect(!mousePressLandedInOtherApplication(pressedWindowID: WindowID(rawValue: 8),
      pressedWindowIsManaged: false, focusedProcessID: 10, windows: windows))
    #expect(!mousePressLandedInOtherApplication(pressedWindowID: WindowID(rawValue: 7),
      pressedWindowIsManaged: true, focusedProcessID: 10, windows: windows))
    #expect(!mousePressLandedInOtherApplication(pressedWindowID: WindowID(rawValue: 9),
      pressedWindowIsManaged: false, focusedProcessID: 10, windows: windows))
  }
}
