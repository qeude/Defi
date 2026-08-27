# macOS overview design

Research completed on August 23, 2026 using Apple's public documentation and
implementation experiments.

## Decision

Defi should render its own overview from logical monitor, workspace, column,
and window state. The overview must remain useful without Screen Recording by
showing cards with application icons, titles, and layout geometry.

Real window previews should be optional. When enabled, capture each window with
`SCScreenshotManager` only while opening the overview. Keep the images in memory
for the life of the overview and fall back to the logical card when capture is
unavailable.

This design uses public AppKit, Core Graphics, and ScreenCaptureKit APIs. It does
not need a private WindowServer overlay or a permanent capture stream.

## Why not use Mission Control

Mission Control provides real previews without Defi requesting Screen Recording,
but macOS does not know Defi's virtual workspace layout. It cannot display the
same monitor, workspace, column, and window structure as Defi.

A custom `NSPanel` per monitor can represent that structure and support keyboard
navigation, pointer selection, search, closing windows, and structural moves.
The primary panel accepts keyboard input while the other monitor panels remain
visible.

## Screen Recording permission

ScreenCaptureKit requires consent before an application captures other
applications without the system picker. macOS stores the revocable permission
under Privacy & Security. The application also needs an
`NSScreenCaptureUsageDescription` entry. The framework reports denied access.

- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Screen and system audio recording access](https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac)

The permission is broader than Defi's managed windows. `SCContentSharingPicker`
offers narrower session access, but requiring the user to select every managed
window would break instant overview opening and would not automatically cover
new windows.

- [`SCContentSharingPicker`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker)
- [Apple's picker authorization model](https://developer.apple.com/videos/play/wwdc2023/10053/?time=377)

Request Screen Recording only when the user enables previews. The overview must
work before the request and after denial. A newly granted permission may require
a clean service restart.

## Capture lifecycle and cost

An unused permission has no capture cadence. A `SCStream` emits frames only
between `startCapture()` and `stopCapture()`. Defi does not need a stream for
overview thumbnails because `SCScreenshotManager.captureImage` performs a
one-shot asynchronous capture.

- [`SCStream`](https://developer.apple.com/documentation/screencapturekit/scstream)
- [One-shot screenshots](https://developer.apple.com/videos/play/wwdc2023/10136/?time=586)

Apple publishes no fixed cost for a burst of window captures. Limit concurrency
only after measuring real hardware. Do not keep a GPU-backed capture pipeline
alive while the overview is closed.

ScreenCaptureKit supports multiple streams and multiple applications using
capture at the same time. That does not guarantee free GPU or memory bandwidth.
One-shot, image-only captures avoid permanent competition with screen-sharing
software.

Protected video can still produce blank regions. A permission does not override
`AVSampleBufferDisplayLayer.preventsCapture`, FairPlay restrictions, or other
protected-content rules. Treat an empty preview as a normal fallback case and
do not retry it indefinitely.

- [`preventsCapture`](https://developer.apple.com/documentation/avfoundation/avsamplebufferdisplaylayer/preventscapture)
- [`allowsCaptureOfClearKeyVideo`](https://developer.apple.com/documentation/avfoundation/avplayer/allowscaptureofclearkeyvideo)

## Screen sharing

When another application shares an entire display, Defi's visible overview is
part of that display. Its cards, titles, and previews can expose windows from
other virtual workspaces. Window-only or application-only sharing excludes the
overview unless the user explicitly shares Defi.

This behavior exists with or without preview capture. The visible overview is
the disclosure. Defi should document it in the same terms as opening Mission
Control during full-screen sharing.

`NSWindow.sharingType = .none` cannot guarantee exclusion. Apple marks that
setting as an obsolete compatibility value. The capturing application controls
its own content filter.

- [ScreenCaptureKit content filters](https://developer.apple.com/videos/play/wwdc2022/10155/?time=282)
- [`NSWindow.SharingType`](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum)

## Offscreen and parked windows

Use a `desktopIndependentWindow` filter and request shareable content with
`onScreenWindowsOnly: false`. Apple documents that this captures a window even
when it is covered, offscreen, on another display, or on another Space. This
matches Defi's position-based parking model.

Minimized windows are different because their capture pauses until restoration.
Defi does not minimize managed windows. Where available,
`ignoreGlobalClipSingleWindow` includes content beyond the original display's
clipping bounds.

- [Capturing offscreen windows](https://developer.apple.com/videos/play/wwdc2022/10155/?time=575)
- [`onScreenWindowsOnly`](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getexcludingdesktopwindows(_:onscreenwindowsonly:completionhandler:))
- [`ignoreGlobalClipSingleWindow`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/ignoreglobalclipsinglewindow)

ScreenCaptureKit guarantees composition of an offscreen window, not that its
owning application redraws fresh content while hidden. Accept a stale preview
and use the logical card when capture fails.

## Product behavior

Ship the complete overview without Screen Recording. Add real previews as an
explicit, disabled-by-default option. When enabled:

1. request permission from the overview or settings;
2. capture each window once with `SCScreenshotManager` and a
   `desktopIndependentWindow` filter;
3. use `onScreenWindowsOnly: false` and `ignoreGlobalClipSingleWindow: true`;
4. keep no audio or permanent stream;
5. discard previews when the overview closes;
6. preserve icon, title, and geometry cards for denial, protected content,
   stale images, and capture errors.
