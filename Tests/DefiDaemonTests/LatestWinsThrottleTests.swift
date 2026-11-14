import Testing

@testable import DefiDaemon

@MainActor
struct LatestWinsThrottleTests {
  @Test
  func `A burst posts its first and last value, and a lone change posts at once`() {
    var timers: [@MainActor () -> Void] = []
    var delivered: [Int] = []
    let throttle = LatestWinsThrottle<Int>(
      interval: 0.05,
      schedule: { _, fire in timers.append(fire) },
      deliver: { delivered.append($0) }
    )
    func fireTimer() { timers.removeFirst()() }

    throttle.submit(1)
    throttle.submit(2)
    throttle.submit(3)
    #expect(delivered == [1])
    fireTimer()
    #expect(delivered == [1, 3])
    fireTimer()
    #expect(timers.isEmpty)

    throttle.submit(4)
    #expect(delivered == [1, 3, 4])
  }
}
