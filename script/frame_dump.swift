import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo(
  [.optionOnScreenOnly], kCGNullWindowID) as! [[CFString: Any]]
let daemonPID = Int(ProcessInfo.processInfo.environment["DAEMON_PID"] ?? "0")!
for w in list {
  let pid = w[kCGWindowOwnerPID] as? Int ?? 0
  let name = w[kCGWindowName] as? String ?? ""
  let owner = w[kCGWindowOwnerName] as? String ?? ""
  let bounds = w[kCGWindowBounds] as! [String: CGFloat]
  let layer = w[kCGWindowLayer] as? Int ?? 0
  if owner == "Ghostty" || pid == daemonPID {
    print("pid=\(pid) owner=\(owner) layer=\(layer) name='\(name)' "
      + "x=\(bounds["X"]!) y=\(bounds["Y"]!) w=\(bounds["Width"]!) h=\(bounds["Height"]!)")
  }
}
