import DefiIPC
import DefiMacOS
import DefiModel
import Testing

@testable import DefiDaemon

struct WindowPreviewResponseTests {
  @Test
  func `window-preview answers from the capture store and explains a missing picture`() {
    let preview: (WindowID) -> Result<String, WindowPreviewError> = { id in
      switch id.rawValue {
      case 51: .success("data:image/jpeg;base64,AA==")
      case 52: .failure(.notAuthorized)
      default: .failure(.noPicture)
      }
    }
    #expect(windowPreviewResponse("window-preview 51", preview: preview) == .success("data:image/jpeg;base64,AA=="))
    #expect(
      windowPreviewResponse("window-preview 52", preview: preview)
        == .failure("Defi needs Screen Recording to show window pictures."))
    #expect(
      windowPreviewResponse("window-preview 53", preview: preview) == .failure("Defi has no picture of window 53 yet."))
    #expect(windowPreviewResponse("window-preview", preview: preview) == .failure("usage: window-preview <window-id>"))
    #expect(windowPreviewResponse("window-preview x", preview: preview) == .failure("usage: window-preview <window-id>"))
    #expect(windowPreviewResponse("list-windows --json", preview: preview) == nil)
  }
}
