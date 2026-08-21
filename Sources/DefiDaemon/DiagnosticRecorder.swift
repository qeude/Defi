import DefiMacOS
import DefiModel
import Foundation
import OSLog

private let diagnosticLogger = Logger(
  subsystem: "com.quentin.defi",
  category: "Diagnostics"
)

struct CommandDiagnosticMetadata: Sendable {
  let timestamp: Date
  let inputTimestamp: TimeInterval
  let command: String
  let generation: UInt64
  let monitorID: MonitorID?
  let workspaceID: WorkspaceID?
  let windowID: WindowID?
  let applicationID: String?
  let processID: Int32?
  var queueWaitMS: Double?
}

private struct PersistentDiagnosticRecord: Encodable {
  let schemaVersion = 1
  let kind: String
  let timestamp: Date
  let uptimeSeconds: TimeInterval
  let sessionID: String
  let build: String
  var command: String?
  var generation: UInt64?
  var monitorID: UInt64?
  var workspaceID: String?
  var windowID: UInt64?
  var applicationID: String?
  var processID: Int32?
  var outcome: String?
  var expectedWindowCount: Int?
  var expectsFocus: Bool?
  var planMS: Double?
  var queueWaitMS: Double?
  var firstWriteMS: Double?
  var firstObservationMS: Double?
  var convergenceMS: Double?
  var focusMS: Double?
  var event: String?
  var status: String?
  var trace: String?
}

final class DiagnosticRecorder: @unchecked Sendable {
  static let defaultDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Logs/Defi/Diagnostics", directoryHint: .isDirectory)

  let directoryURL: URL
  let maximumFileSize: Int
  let fileCount: Int

  private let queue = DispatchQueue(
    label: "com.quentin.defi.diagnostics",
    qos: .utility
  )
  private let sessionID = UUID().uuidString
  private let build: String
  private var commands: [UInt64: CommandDiagnosticMetadata] = [:]

  init(
    directoryURL: URL = DiagnosticRecorder.defaultDirectoryURL,
    maximumFileSize: Int = 10 * 1_024 * 1_024,
    fileCount: Int = 3,
    build: String = DiagnosticRecorder.currentBuild
  ) {
    self.directoryURL = directoryURL
    self.maximumFileSize = maximumFileSize
    self.fileCount = fileCount
    self.build = build
  }

  func beginCommand(_ metadata: CommandDiagnosticMetadata) {
    queue.async { [self] in
      commands[metadata.generation] = metadata
    }
  }

  func record(_ sample: CommandDiagnosticSample) {
    queue.async { [self] in
      let metadata = commands.removeValue(forKey: sample.generation)
      var record = makeRecord(
        kind: "command",
        timestamp: metadata?.timestamp ?? Date(),
        uptime: sample.inputTimestamp
      )
      record.command = metadata?.command
      record.generation = sample.generation
      record.monitorID = metadata?.monitorID?.rawValue
      record.workspaceID = metadata?.workspaceID?.rawValue
      record.windowID = metadata?.windowID?.rawValue
      record.applicationID = metadata?.applicationID
      record.processID = metadata?.processID
      record.outcome = sample.outcome.rawValue
      record.expectedWindowCount = sample.expectedWindowCount
      record.expectsFocus = sample.expectsFocus
      record.queueWaitMS = metadata?.queueWaitMS
      record.planMS = sample.planMS
      record.firstWriteMS = sample.firstWriteMS
      record.firstObservationMS = sample.firstObservationMS
      record.convergenceMS = sample.convergenceMS
      record.focusMS = sample.focusMS
      append(record)
    }
  }

  func recordNoOp(
    _ metadata: CommandDiagnosticMetadata,
    durationMS: Double
  ) {
    queue.async { [self] in
      var record = makeRecord(
        kind: "command",
        timestamp: metadata.timestamp,
        uptime: metadata.inputTimestamp
      )
      record.command = metadata.command
      record.generation = metadata.generation
      record.monitorID = metadata.monitorID?.rawValue
      record.workspaceID = metadata.workspaceID?.rawValue
      record.windowID = metadata.windowID?.rawValue
      record.applicationID = metadata.applicationID
      record.processID = metadata.processID
      record.outcome = "no-op"
      record.expectedWindowCount = 0
      record.expectsFocus = false
      record.queueWaitMS = metadata.queueWaitMS
      record.planMS = durationMS
      record.convergenceMS = durationMS
      append(record)
    }
  }

  func recordAnomaly(uptime: TimeInterval, event: String) {
    queue.async { [self] in
      var record = makeRecord(kind: "anomaly", timestamp: Date(), uptime: uptime)
      record.event = event
      append(record)
    }
  }

  func mark(status: String, trace: String) {
    queue.async { [self] in
      var record = makeRecord(
        kind: "marker",
        timestamp: Date(),
        uptime: ProcessInfo.processInfo.systemUptime
      )
      record.status = status
      record.trace = trace
      append(record)
    }
  }

  func flush() {
    queue.sync {}
  }

  var currentFileURL: URL {
    fileURL(at: 0)
  }

  private func makeRecord(
    kind: String,
    timestamp: Date,
    uptime: TimeInterval
  ) -> PersistentDiagnosticRecord {
    PersistentDiagnosticRecord(
      kind: kind,
      timestamp: timestamp,
      uptimeSeconds: uptime,
      sessionID: sessionID,
      build: build
    )
  }

  private func append(_ record: PersistentDiagnosticRecord) {
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(record)
      data.append(0x0A)
      guard data.count <= maximumFileSize else {
        diagnosticLogger.error("Diagnostic record exceeds the file size limit")
        return
      }
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true
      )
      if currentFileSize + data.count > maximumFileSize {
        try rotate()
      }
      let url = currentFileURL
      if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } else {
        try data.write(to: url, options: .atomic)
      }
    } catch {
      diagnosticLogger.error("Unable to write diagnostics: \(error.localizedDescription)")
    }
  }

  private var currentFileSize: Int {
    let attributes = try? FileManager.default.attributesOfItem(
      atPath: currentFileURL.path
    )
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
  }

  private func rotate() throws {
    guard fileCount > 1 else {
      try? FileManager.default.removeItem(at: currentFileURL)
      return
    }
    for index in stride(from: fileCount - 1, through: 1, by: -1) {
      let source = fileURL(at: index - 1)
      let destination = fileURL(at: index)
      try? FileManager.default.removeItem(at: destination)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.moveItem(at: source, to: destination)
      }
    }
  }

  private func fileURL(at index: Int) -> URL {
    let name = index == 0 ? "diagnostics.jsonl" : "diagnostics.\(index).jsonl"
    return directoryURL.appending(path: name)
  }

  private static var currentBuild: String {
    let version = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "development"
    let build = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleVersion"
    ) as? String ?? "unknown"
    return "\(version) (\(build))"
  }
}
