// Prints one JSON line describing a process's windows as WindowServer and Accessibility see them.
// Usage: window-dump PID
import AppKit
import ApplicationServices

typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWindow = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
  .map { unsafeBitCast($0, to: GetWindow.self) }

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func point(_ value: CFTypeRef?, _ type: AXValueType) -> [Double]? {
  guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  if type == .cgPoint {
    var p = CGPoint.zero
    return AXValueGetValue(value as! AXValue, type, &p) ? [p.x, p.y] : nil
  }
  var s = CGSize.zero
  return AXValueGetValue(value as! AXValue, type, &s) ? [s.width, s.height] : nil
}

let pid = pid_t(CommandLine.arguments[1])!
let records = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
  .filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) && ($0[kCGWindowLayer as String] as? Int) == 0 }
  .map { r -> [String: Any] in
    let b = r[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return ["id": r[kCGWindowNumber as String] ?? 0, "onscreen": r[kCGWindowIsOnscreen as String] ?? false,
            "title": r[kCGWindowName as String] ?? "", "frame": [b["X"], b["Y"], b["Width"], b["Height"]]]
  }
let app = AXUIElementCreateApplication(pid)
let axWindows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { w -> [String: Any] in
  var id: CGWindowID = 0
  _ = getWindow?(w, &id)
  return ["id": id, "title": attribute(w, kAXTitleAttribute) as? String ?? "",
          "position": point(attribute(w, kAXPositionAttribute), .cgPoint) ?? [],
          "size": point(attribute(w, kAXSizeAttribute), .cgSize) ?? [],
          "main": attribute(w, kAXMainAttribute) as? Bool ?? false,
          "minimized": attribute(w, kAXMinimizedAttribute) as? Bool ?? false,
          "children": (attribute(w, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { child -> [String: Any] in
            ["role": attribute(child, kAXRoleAttribute) as? String ?? "",
             "position": point(attribute(child, kAXPositionAttribute), .cgPoint) ?? [],
             "size": point(attribute(child, kAXSizeAttribute), .cgSize) ?? [],
             "tabs": (attribute(child, kAXTabsAttribute) as? [AXUIElement])?.count ?? -1]
          }]
}
let data = try JSONSerialization.data(withJSONObject: ["cg": records, "ax": axWindows], options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
