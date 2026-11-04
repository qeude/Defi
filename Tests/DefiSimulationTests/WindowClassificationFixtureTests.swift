import Foundation
import Testing

@testable import DefiMacOS

/// Windows recorded with `defi debug-windows` on a real desktop (attributes only, no titles).
/// Each records the disposition Defi chose when it was recorded; a change in classification
/// shows up here for review instead of on the desktop.
struct WindowClassificationFixtureTests {
  static let records: [WindowAttributeRecord] = {
    let url = Bundle.module.url(forResource: "recorded-windows", withExtension: "json", subdirectory: "Fixtures")!
    return try! JSONDecoder().decode([WindowAttributeRecord].self, from: Data(contentsOf: url))
  }()

  @Test(arguments: records.indices)
  func recordedWindowKeepsItsDisposition(index: Int) {
    let record = Self.records[index]
    #expect(record.currentDisposition == record.disposition, "\(record)")
  }
}
