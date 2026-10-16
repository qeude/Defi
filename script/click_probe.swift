import CoreGraphics
import Foundation

// Tear-probe helper: `click-probe WINDOW_NUMBER` posts a real left click at the centre of the
// window's on-screen part of the main display, as a native click during motion would.
let windowNumber = CGWindowID(CommandLine.arguments[1])!
let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowNumber) as? [[String: Any]])?.first
var rect = CGRect.zero
guard let bounds = info?[kCGWindowBounds as String] as? NSDictionary,
  CGRectMakeWithDictionaryRepresentation(bounds, &rect)
else { exit(1) }
let visible = rect.intersection(CGDisplayBounds(CGMainDisplayID()))
guard !visible.isNull else { exit(2) }
let point = CGPoint(x: visible.midX, y: visible.midY)
// Report what is under the click: the window may have moved since its bounds were read.
let hit = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
  as? [[String: Any]])?.first {
    var frame = CGRect.zero
    return ($0[kCGWindowLayer as String] as? Int) == 0
      && CGRectMakeWithDictionaryRepresentation(($0[kCGWindowBounds as String] as! NSDictionary), &frame)
      && frame.contains(point)
  }?[kCGWindowNumber as String] as? Int ?? -1
print(ProcessInfo.processInfo.systemUptime, hit)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
    .post(tap: .cghidEventTap)
  usleep(20_000)
}
