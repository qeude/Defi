import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

private struct CapturedFrame: Sendable {
  let timestamp: Double
  let pixels: [UInt8]
}

private final class DisplaySampler: NSObject, SCStreamOutput, @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [CapturedFrame] = []
  private let readyURL: URL
  private let widthSamples = 512
  private let heightSamples = 40

  init(readyURL: URL) {
    self.readyURL = readyURL
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .screen,
      CMSampleBufferIsValid(sampleBuffer),
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else { return }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var signature = [UInt8](repeating: 0, count: widthSamples * heightSamples)

    for sampleY in 0..<heightSamples {
      let y = min((sampleY * height) / heightSamples, height - 1)
      for sampleX in 0..<widthSamples {
        let x = min((sampleX * width) / widthSamples, width - 1)
        let pixel = bytes.advanced(by: y * rowBytes + x * 4)
        signature[sampleY * widthSamples + sampleX] = UInt8(
          (UInt16(pixel[0]) * 29 + UInt16(pixel[1]) * 150 + UInt16(pixel[2]) * 77) >> 8
        )
      }
    }

    let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    guard timestamp.isFinite else { return }
    lock.lock()
    frames.append(CapturedFrame(timestamp: timestamp, pixels: signature))
    if frames.count == 1 {
      FileManager.default.createFile(atPath: readyURL.path, contents: Data())
    }
    lock.unlock()
  }

  func snapshot() -> [CapturedFrame] {
    lock.lock()
    defer { lock.unlock() }
    return frames
  }
}

private func bestShift(
  previous: [UInt8], current: [UInt8], region: Int, regionWidth: Int = 128,
  imageWidth: Int = 512, rows: Int = 40, maxShift: Int = 20
) -> (shiftSamples: Int, confidence: Double, clipped: Bool) {
  let startX = region * regionWidth
  var zeroError = 0.0
  var bestError = Double.infinity
  var best = 0
  for shift in -maxShift...maxShift {
    let lower = max(startX, startX - shift)
    let upper = min(startX + regionWidth, startX + regionWidth - shift)
    var error = 0
    var comparedPixels = 0
    for y in 0..<rows {
      let rowStart = y * imageWidth
      for x in lower..<upper {
        let oldValue = Int(previous[rowStart + x + shift])
        let newValue = Int(current[rowStart + x])
        error += abs(oldValue - newValue)
        comparedPixels += 1
      }
    }
    let meanError = Double(error) / Double(max(comparedPixels, 1))
    if shift == 0 { zeroError = meanError }
    if meanError < bestError {
      bestError = meanError
      best = shift
    }
  }
  let confidence = zeroError - bestError
  return (best, confidence, abs(best) == maxShift)
}

private func analyze(_ frames: [CapturedFrame], displayWidth: Int) -> String {
  var rows = ["timestamp_s,interval_ms,zone0_dx_px,zone0_confidence,zone0_clipped,zone1_dx_px,zone1_confidence,zone1_clipped,zone2_dx_px,zone2_confidence,zone2_clipped,zone3_dx_px,zone3_confidence,zone3_clipped"]
  guard frames.count > 1 else { return rows.joined(separator: "\n") + "\n" }
  let scale = Double(displayWidth) / 512
  for index in 1..<frames.count {
    let previous = frames[index - 1]
    let current = frames[index]
    let interval = (current.timestamp - previous.timestamp) * 1_000
    var fields = [String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), current.timestamp),
                  String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), interval)]
    for zone in 0..<4 {
      let estimate = bestShift(previous: previous.pixels, current: current.pixels, region: zone)
      let shift = estimate.confidence >= 3.0 && !estimate.clipped
        ? -Double(estimate.shiftSamples) * scale : 0
      fields.append(String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), shift))
      fields.append(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), estimate.confidence))
      fields.append(estimate.clipped ? "true" : "false")
    }
    rows.append(fields.joined(separator: ","))
  }
  return rows.joined(separator: "\n") + "\n"
}

@main
private struct AnimationCapture {
  @MainActor
  static func main() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 5, let duration = Double(args[0]), duration > 0, duration <= 120,
      let displayID = UInt32(args[1]), displayID > 0
    else {
      fputs(
        "usage: animation-capture <duration-seconds<=120> <display-id> "
          + "<ready-file> <output-csv> <stop-file>\n",
        stderr
      )
      exit(2)
    }
    guard CGPreflightScreenCaptureAccess() else {
      fputs("Screen Recording is unavailable to this process; no capture was started.\n", stderr)
      exit(3)
    }
    let readyURL = URL(fileURLWithPath: args[2])
    let outputURL = URL(fileURLWithPath: args[3])
    let stopURL = URL(fileURLWithPath: args[4])
    let captureDisplayID = CGDirectDisplayID(displayID)
    let content = try await SCShareableContent.excludingDesktopWindows(
      true, onScreenWindowsOnly: false
    )
    guard let display = content.displays.first(where: { $0.displayID == captureDisplayID }) else {
      throw NSError(domain: "AnimationCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Requested display was not available for capture"])
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
    configuration.queueDepth = 5
    configuration.showsCursor = false
    configuration.capturesAudio = false
    let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
    let sampler = DisplaySampler(readyURL: readyURL)
    let queue = DispatchQueue(label: "com.defi.animation-benchmark.capture", qos: .userInteractive)
    try stream.addStreamOutput(sampler, type: .screen, sampleHandlerQueue: queue)
    try await stream.startCapture()
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    while ProcessInfo.processInfo.systemUptime < deadline,
      !FileManager.default.fileExists(atPath: stopURL.path)
    {
      try await Task.sleep(for: .milliseconds(50))
    }
    try await stream.stopCapture()
    let frames = sampler.snapshot()
    try analyze(frames, displayWidth: display.width).write(
      to: outputURL, atomically: true, encoding: .utf8
    )
    print("Captured \(frames.count) display frames at \(display.width)x\(display.height)")
  }
}
