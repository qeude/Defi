import AppKit
import IOKit
@testable import DefiMacOS

/// Three-finger trackpad gesture events like the ones macOS sends, built with IOKit's private HID
/// event calls. AppKit reads their touches only for a multitouch device it finds in the registry.
struct TrackpadGesture {
  private typealias Collection = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32,
    UInt32, Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>
  private typealias Finger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
    Double, Double, Double, Double, Double, Bool, Bool, UInt32) -> Unmanaged<CFTypeRef>
  private typealias Vendor = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32,
    UnsafePointer<UInt8>, Int, UInt32) -> Unmanaged<CFTypeRef>
  private typealias Append = @convention(c) (CFTypeRef, CFTypeRef, UInt32) -> Void
  private typealias SetInteger = @convention(c) (CFTypeRef, UInt32, Int) -> Void
  private typealias Attach = @convention(c) (CGEvent, CFTypeRef) -> Void
  private let collection: Collection, finger: Finger, vendor: Vendor
  private let append: Append, setInteger: SetInteger, attach: Attach
  private let registryID: UInt64

  /// Whether a three-finger swipe may pan vertically, or nil when there is no trackpad
  /// or the Trackpad settings give both axes to macOS.
  static var freeAxis: Bool? {
    let system = systemTrackpadSwipes(fingers: 3)
    return TrackpadGesture() == nil || system.horizontal && system.vertical ? nil : system.horizontal
  }

  init?() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var registryID: UInt64 = 0
    guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
      let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL),
      let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    else { return nil }
    func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as _: T.Type) -> T? {
      dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
    }
    guard let collection = load(iokit, "IOHIDEventCreateDigitizerEvent", as: Collection.self),
      let finger = load(iokit, "IOHIDEventCreateDigitizerFingerEvent", as: Finger.self),
      let vendor = load(iokit, "IOHIDEventCreateVendorDefinedEvent", as: Vendor.self),
      let append = load(iokit, "IOHIDEventAppendEvent", as: Append.self),
      let setInteger = load(iokit, "IOHIDEventSetIntegerValue", as: SetInteger.self),
      let attach = load(skyLight, "SLEventSetIOHIDEvent", as: Attach.self)
    else { return nil }
    (self.collection, self.finger, self.vendor) = (collection, finger, vendor)
    (self.append, self.setInteger, self.attach, self.registryID) = (append, setInteger, attach, registryID)
  }

  /// Three fingers side by side from `point`, in normalized trackpad coordinates.
  func event(at point: CGPoint, touching: Bool = true, flags: CGEventFlags) -> CGEvent? {
    let time = mach_absolute_time(), digitizer: UInt32 = 11, touchAndPosition: UInt32 = 0x6
    let paths = collection(nil, time, 3, 0, 0, touchAndPosition, 0, point.x, point.y, 0, 0, 0,
      touching, touching, 0).takeRetainedValue()
    setInteger(paths, digitizer << 16 | 22, 1)
    // AppKit reads the paths as a trackpad's only beside this vendor child naming the device.
    var device = registryID
    let data = withUnsafeBytes(of: &device) { Array($0) } + [UInt8](repeating: 0, count: 8)
    append(paths, vendor(nil, time, 0xff00, 0x1777, 1, data, data.count, 0).takeRetainedValue(), 0)
    for index in 1...3 {
      append(paths, finger(nil, time, UInt32(index), UInt32(index), touchAndPosition,
        point.x + Double(index) * 0.05, point.y, 0, touching ? 1 : 0, 0, touching, touching, 0).takeRetainedValue(), 0)
    }
    guard let event = CGEvent(source: nil), let type = CGEventType(rawValue: gestureEventType) else { return nil }
    event.type = type
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: Int64(digitizer))
    event.setIntegerValueField(CGEventField(rawValue: 87)!, value: Int64(registryID))
    event.flags = flags
    attach(event, paths)
    return event
  }

  /// A swipe a fifth of the trackpad long, then the lift.
  func swipe(vertical: Bool, flags: CGEventFlags = []) -> [CGEvent] {
    (0...10).compactMap { step in
      let along = 0.5 - Double(step) * 0.02
      return event(at: vertical ? CGPoint(x: 0.5, y: along) : CGPoint(x: along, y: 0.5), flags: flags)
    } + [event(at: CGPoint(x: 0.3, y: 0.3), touching: false, flags: flags)].compactMap { $0 }
  }
}
