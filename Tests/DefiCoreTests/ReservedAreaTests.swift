import DefiCore
import DefiModel
import Testing

struct ReservedAreaTests {
  @Test
  func appliesTopAndBottomInsets() {
    let viewport = Rect(x: 10, y: 20, width: 1_000, height: 800)

    let result = viewportByApplyingReservedEdges(
      viewport,
      edges: ReservedEdges(top: 12, bottom: 18)
    )

    #expect(result == Rect(x: 10, y: 32, width: 1_000, height: 770))
  }

  @Test
  func clampsInsetsToAvailableHeight() {
    let result = viewportByApplyingReservedEdges(
      Rect(x: 0, y: 0, width: 100, height: 40),
      edges: ReservedEdges(top: 30, bottom: 30)
    )

    #expect(result == Rect(x: 0, y: 30, width: 100, height: 0))
  }
}
