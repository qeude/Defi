import AVFoundation
import CoreMedia
import CoreVideo

// Wrap existing pixels for the public video renderer; no compression or bitmap copy.
@MainActor
func enqueueWindowSurface(_ frame: OverviewSurfaceFrame, on layer: AVSampleBufferDisplayLayer) -> Bool {
  var format: CMVideoFormatDescription?
  guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: frame.buffer, formatDescriptionOut: &format) == noErr,
    let format else { return false }
  var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero,
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
    imageBuffer: frame.buffer, formatDescription: format, sampleTiming: &timing,
    sampleBufferOut: &sample) == noErr, let sample,
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
    CFArrayGetCount(attachments) > 0 else { return false }
  // Core Media specifies that this array contains mutable CF dictionaries.
  let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
  CFDictionarySetValue(attachment,
    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
  layer.sampleBufferRenderer.enqueue(sample)
  return true
}
