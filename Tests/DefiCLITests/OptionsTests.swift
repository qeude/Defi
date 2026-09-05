import Testing

@testable import DefiCLI

struct OptionsTests {
  @Test
  func parsesMonitorTargetBeforeCommand() throws {
    let options = try Options(
      arguments: ["--monitor", "2", "workspace", "web"]
    )

    #expect(options.monitorIndex == 2)
    #expect(options.command == ["workspace", "web"])
  }

  @Test(arguments: ["0", "not-a-number"])
  func rejectsInvalidMonitorIndex(value: String) {
    #expect(throws: CLIError.usage) {
      try Options(arguments: ["--monitor", value, "workspace", "web"])
    }
  }

  @Test
  func requiresExplicitPurgeForCompleteUninstall() throws {
    let options = try Options(arguments: ["uninstall", "--purge"])

    #expect(options.purge)
    #expect(options.command.isEmpty)
  }
}
