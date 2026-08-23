import DefiMacOS
import DefiModel
import Foundation
import Testing

@testable import DefiDaemon

struct DiagnosticRecorderTests {
  @Test
  func writesCommandAndMarkerWithoutWindowContent() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = DiagnosticRecorder(
      directoryURL: directory,
      maximumFileSize: 32_768,
      build: "test"
    )
    recorder.beginCommand(
      CommandDiagnosticMetadata(
        timestamp: Date(timeIntervalSince1970: 1),
        inputTimestamp: 10,
        command: "focus-column right",
        generation: 7,
        monitorID: MonitorID(rawValue: 2),
        workspaceID: WorkspaceID(rawValue: "dev"),
        windowID: WindowID(rawValue: 3),
        applicationID: "com.example.Editor",
        processID: 4
      )
    )
    recorder.record(
      CommandDiagnosticSample(
        generation: 7,
        inputTimestamp: 10,
        expectedWindowCount: 2,
        expectsFocus: true,
        planMS: 2,
        firstWriteMS: 3,
        firstObservationMS: 8,
        convergenceMS: 10,
        focusMS: 12,
        outcome: .completed
      )
    )
    recorder.mark(status: "running", trace: "command-converged cg=7")
    recorder.flush()

    let contents = try String(contentsOf: recorder.currentFileURL, encoding: .utf8)
    let lines = contents.split(separator: "\n")
    #expect(lines.count == 2)
    #expect(contents.contains("\"applicationID\":\"com.example.Editor\""))
    #expect(contents.contains("\"kind\":\"marker\""))
    #expect(contents.contains("windowTitle") == false)
    #expect(contents.contains("document") == false)
  }

  @Test
  func rotatesWithinTheConfiguredFileCountAndSize() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = DiagnosticRecorder(
      directoryURL: directory,
      maximumFileSize: 700,
      fileCount: 3,
      build: "test"
    )

    for index in 0..<20 {
      recorder.recordAnomaly(
        uptime: Double(index),
        event: "slow \(String(repeating: "x", count: 180))"
      )
    }
    recorder.flush()

    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey]
    )
    #expect(files.count == 3)
    for file in files {
      let values = try file.resourceValues(forKeys: [.fileSizeKey])
      #expect((values.fileSize ?? 0) <= 700)
    }
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "defi-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}
