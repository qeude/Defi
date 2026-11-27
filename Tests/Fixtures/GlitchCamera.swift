// Test-only observer for script/glitch_bench.py, run in the defi-e2e VM: logs what the screen shows.
// Usage: GlitchCamera OUT.jsonl HUE,HUE,...   records until stdin closes
//        GlitchCamera click X Y               a real left click at CG coordinates
//        GlitchCamera key PID KEYCODE         one key press delivered to that process only
//        GlitchCamera cmdtab                  a real Command-Tab, to the previous app
// Each changed frame logs the runs of fixture colours on three rows of every display ("w<index>",
// "ph" for a placeholder card), and every 33 ms the on-screen bounds of fixture and Defi windows.
import AppKit
import CoreMedia
import ScreenCaptureKit

let placeholderRGB = (15.0, 15.0, 20.0)
let rows: [Double] = [0.3, 0.5, 0.75]

struct Palette {
  let hues: [Double]

  func label(_ r: Double, _ g: Double, _ b: Double) -> String? {
    if abs(r - placeholderRGB.0) < 6, abs(g - placeholderRGB.1) < 6, abs(b - placeholderRGB.2) < 6 { return "ph" }
    let maxValue = max(r, g, b), minValue = min(r, g, b)
    guard maxValue > 200, (maxValue - minValue) / maxValue > 0.35 else { return nil }
    var hue: Double
    let delta = maxValue - minValue
    if maxValue == r { hue = (g - b) / delta } else if maxValue == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
    hue = (hue / 6).truncatingRemainder(dividingBy: 1)
    if hue < 0 { hue += 1 }
    var best: (Int, Double)?
    for (index, value) in hues.enumerated() {
      let distance = min(abs(hue - value), 1 - abs(hue - value))
      if distance < 0.03, distance < (best?.1 ?? 1) { best = (index, distance) }
    }
    return best.map { "w\($0.0)" }
  }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let palette: Palette
  let out: FileHandle
  let display: SCDisplay
  let queue = DispatchQueue(label: "camera")
  var previous = ""
  var lastWindows = 0.0
  var previousWindows = ""
  var frames = 0

  init(palette: Palette, out: FileHandle, display: SCDisplay) {
    self.palette = palette
    self.out = out
    self.display = display
  }

  var restart: (() -> Void)?

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    write(["t": ProcessInfo.processInfo.systemUptime, "error": "\(error)", "d": display.displayID])
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.restart?() }
  }

  func write(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
      out.write(data + Data([10]))
    }
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
      let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
    frames += 1
    let at = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
    let scale = Double(display.frame.width) / Double(width)
    var lines: [[[Any]]] = []
    for fraction in rows {
      let y = min(height - 1, Int(Double(height) * fraction))
      var runs: [[Any]] = []
      var current: (String, Int)?
      func close(_ end: Int) {
        // Runs under 4 px are borders, anti-aliasing or photo noise.
        if let (label, start) = current, end - start >= 4 {
          runs.append([label, Int((Double(start) * scale).rounded()), Int((Double(end) * scale).rounded())])
        }
        current = nil
      }
      for x in 0..<width {
        let p = base + y * stride + x * 4
        let label = palette.label(Double(p[2]), Double(p[1]), Double(p[0]))
        if label != current?.0 {
          close(x)
          if let label { current = (label, x) }
        }
      }
      close(width)
      lines.append(runs)
    }
    let key = "\(lines)"
    if key != previous {
      previous = key
      write(["t": at, "d": display.displayID, "rows": lines])
    } else {
      // A frame that changed elsewhere on screen: shows these windows held still meanwhile.
      write(["t": at, "d": display.displayID, "same": 1])
    }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastWindows > 0.033 {
      lastWindows = now
      sampleWindows(now)
    }
  }

  func sampleWindows(_ now: Double) {
    guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
    var rows: [[Any]] = []
    for info in infos {
      let owner = info[kCGWindowOwnerName as String] as? String ?? ""
      guard owner.hasPrefix("PerformanceFixture") || owner == "defi-daemon" || owner == "Defi"
        || owner == "UserNotificationCenter",
        let bounds = info[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
      rows.append([info[kCGWindowNumber as String] as? Int ?? 0, info[kCGWindowOwnerPID as String] as? Int ?? 0,
                   info[kCGWindowLayer as String] as? Int ?? 0, Double(info[kCGWindowAlpha as String] as? Double ?? 1),
                   Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height)])
    }
    let key = "\(rows)"
    if key != previousWindows {
      previousWindows = key
      write(["t": now, "windows": rows])
    }
  }
}

func click(_ x: Double, _ y: Double) {
  let point = CGPoint(x: x, y: y)
  for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(type == .mouseMoved ? 120_000 : 60_000)
  }
}

func key(_ pid: pid_t, _ code: CGKeyCode) {
  for down in [true, false] {
    CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.postToPid(pid)
    usleep(40_000)
  }
}

// Through the HID tap, like the keyboard: Defi only follows an activation a person asked for.
func commandTab() {
  let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
    (55, true, .maskCommand), (48, true, .maskCommand), (48, false, .maskCommand), (55, false, []),
  ]
  for (code, down, flags) in steps {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(60_000)
  }
}

// Events on the HID tap reach whatever app is frontmost: only a virtual machine may receive them.
func requireVirtualMachine() {
  var present: Int32 = 0
  var size = MemoryLayout<Int32>.size
  guard sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0, present == 1 else {
    FileHandle.standardError.write(Data("GlitchCamera: global input runs only inside the defi-e2e VM\n".utf8))
    exit(2)
  }
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "cmdtab" {
  requireVirtualMachine()
  commandTab()
  exit(0)
}
if arguments.count == 4, arguments[1] == "click" {
  requireVirtualMachine()
  click(Double(arguments[2])!, Double(arguments[3])!)
  exit(0)
}
if arguments.count == 4, arguments[1] == "key" {
  key(pid_t(arguments[2])!, CGKeyCode(arguments[3])!)
  exit(0)
}
guard arguments.count == 3, FileManager.default.createFile(atPath: arguments[1], contents: nil),
  let out = FileHandle(forWritingAtPath: arguments[1]) else {
  FileHandle.standardError.write(Data("usage: GlitchCamera OUT.jsonl HUE,...\n".utf8))
  exit(2)
}
let palette = Palette(hues: arguments[2].split(separator: ",").compactMap { Double($0) })
var streams: [SCStream] = []
var recorders: [Recorder] = []
@MainActor func start(_ display: SCDisplay, _ recorder: Recorder) async throws {
  let configuration = SCStreamConfiguration()
  // Half resolution keeps the guest's CPUs for Defi; runs are scaled back to points.
  configuration.width = display.width / 2
  configuration.height = display.height / 2
  configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
  configuration.pixelFormat = kCVPixelFormatType_32BGRA
  configuration.colorSpaceName = CGColorSpace.sRGB
  configuration.showsCursor = false
  configuration.queueDepth = 4
  let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: recorder)
  try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
  try await stream.startCapture()
  streams.append(stream)
}

Task {
  do {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    for display in content.displays {
      let recorder = Recorder(palette: palette, out: out, display: display)
      recorder.restart = {
        Task { @MainActor in
          do { try await start(display, recorder) } catch {
            recorder.write(["t": ProcessInfo.processInfo.systemUptime, "error": "restart: \(error)", "d": display.displayID])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { recorder.restart?() }
          }
        }
      }
      try await start(display, recorder)
      recorders.append(recorder)
      recorder.write(["t": ProcessInfo.processInfo.systemUptime, "display": display.displayID,
                      "frame": [display.frame.minX, display.frame.minY, display.frame.width, display.frame.height]])
    }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
  } catch {
    FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
    exit(1)
  }
}
DispatchQueue.global().async {
  while readLine() != nil {}
  DispatchQueue.main.async {
    Task {
      for stream in streams { try? await stream.stopCapture() }
      for recorder in recorders { recorder.write(["t": ProcessInfo.processInfo.systemUptime, "frames": recorder.frames, "display": recorder.display.displayID]) }
      exit(0)
    }
  }
}
dispatchMain()
