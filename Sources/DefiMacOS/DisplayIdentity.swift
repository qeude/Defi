import ColorSync
import CoreGraphics
import Foundation

public func stableDisplayIdentifier(_ displayID: CGDirectDisplayID) -> String? {
  guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
    let identifier = CFUUIDCreateString(nil, uuid)
  else { return nil }
  return identifier as String
}
