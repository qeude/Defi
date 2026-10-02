import AppKit
import CoreGraphics
import Darwin
import Foundation

@main
private struct AnimationInput {
  static func main() {
    do {
      try dragFocusedDiaWindow()
    } catch {
      fputs("animation-input: \(error.localizedDescription)\n", stderr)
      exit(EXIT_FAILURE)
    }
  }

  private static func dragFocusedDiaWindow() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2,
      let rawWindowID = UInt32(arguments[0]),
      let deltaX = Double(arguments[1]), deltaX.isFinite,
      deltaX != 0, abs(deltaX) <= 200
    else {
      throw failure("Expected a window ID and a horizontal delta between 1 and 200 points")
    }
    guard let application = CGWindowListCopyWindowInfo(
      [.optionIncludingWindow, .optionOnScreenOnly], rawWindowID
    ) as? [[String: Any]],
      let window = application.first(where: {
        ($0[kCGWindowNumber as String] as? Int) == Int(rawWindowID)
      }),
      let processID = window[kCGWindowOwnerPID as String] as? pid_t,
      NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        == "company.thebrowser.dia",
      let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
      let x = bounds["X"], let y = bounds["Y"],
      let width = bounds["Width"], let height = bounds["Height"]
    else {
      throw failure("Focused window is not an on-screen Dia window with readable bounds")
    }

    let frame = CGRect(
      x: x.doubleValue,
      y: y.doubleValue,
      width: width.doubleValue,
      height: height.doubleValue
    )
    let start = CGPoint(x: frame.maxX - 1, y: frame.midY)
    let steps = 12
    let source = CGEventSource(stateID: .hidSystemState)
    for step in 0...steps {
      let point = CGPoint(
        x: start.x + deltaX * Double(step) / Double(steps),
        y: start.y
      )
      let type: CGEventType = step == 0
        ? .leftMouseDown
        : (step == steps ? .leftMouseUp : .leftMouseDragged)
      guard let event = CGEvent(
        mouseEventSource: source,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
      ) else {
        throw failure("Could not create the mouse resize event")
      }
      event.post(tap: .cghidEventTap)
      usleep(8_333)
    }

    usleep(350_000)
    guard let updated = CGWindowListCopyWindowInfo(
      [.optionIncludingWindow, .optionOnScreenOnly], rawWindowID
    ) as? [[String: Any]],
      let updatedWindow = updated.first(where: {
        ($0[kCGWindowNumber as String] as? Int) == Int(rawWindowID)
      }),
      let updatedBounds = updatedWindow[kCGWindowBounds as String] as? [String: NSNumber],
      let updatedWidth = updatedBounds["Width"]?.doubleValue,
      abs(updatedWidth - (frame.width + deltaX)) <= 8
    else {
      throw failure("Dia did not resize to the requested width; windowID=\(rawWindowID)")
    }

    print(
      String(
        format: "window=%u app=company.thebrowser.dia beforeWidth=%.0f afterWidth=%.0f deltaX=%.0f",
        rawWindowID,
        frame.width,
        updatedWidth,
        deltaX
      )
    )
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "DefiAnimationInput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
