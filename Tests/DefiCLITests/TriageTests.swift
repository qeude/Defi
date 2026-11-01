import Foundation
import Testing

@testable import DefiCLI

struct TriageTests {
  @Test
  func parsesTriageWithoutAnAgent() throws {
    let options = try Options(arguments: ["triage"])

    #expect(options.triage)
    #expect(options.triageAgent == nil)
    #expect(options.command.isEmpty)
  }

  @Test
  func parsesTriageWithAnAgentAndSocket() throws {
    let options = try Options(arguments: ["--socket", "/tmp/x.sock", "triage", "--agent", "codex"])

    #expect(options.triage)
    #expect(options.triageAgent == .codex)
    #expect(options.socketURL.path == "/tmp/x.sock")
  }

  @Test(arguments: [
    ["triage", "--agent", "gemini"],
    ["triage", "--agent"],
    ["triage", "extra"],
    ["triage", "--agent", "claude", "extra"],
  ])
  func rejectsInvalidTriageForms(arguments: [String]) {
    #expect(throws: CLIError.usage) {
      try Options(arguments: arguments)
    }
  }

  @Test
  func requestedAgentIsUsedOnlyWhenInstalled() {
    #expect(
      selectTriageAgent(requested: .codex, installed: [.claude, .codex], isInteractive: false)
        == .use(.codex))
    #expect(
      selectTriageAgent(requested: .codex, installed: [.claude], isInteractive: true)
        == .requestedMissing(.codex))
    #expect(
      selectTriageAgent(requested: .claude, installed: [], isInteractive: true)
        == .requestedMissing(.claude))
  }

  @Test
  func singleInstalledAgentIsUsedWithoutAsking() {
    #expect(
      selectTriageAgent(requested: nil, installed: [.codex], isInteractive: false) == .use(.codex))
  }

  @Test
  func noInstalledAgentFallsBackToPasting() {
    #expect(
      selectTriageAgent(requested: nil, installed: [], isInteractive: true) == .noneInstalled)
  }

  @Test
  func bothInstalledAsksOnATerminalAndFailsWithoutOne() {
    #expect(
      selectTriageAgent(requested: nil, installed: [.claude, .codex], isInteractive: true)
        == .ask([.claude, .codex]))
    #expect(
      selectTriageAgent(requested: nil, installed: [.claude, .codex], isInteractive: false)
        == .needsTerminal)
  }

  @Test
  func rendersContextForARunningDaemon() {
    let text = renderTriageContext(context(daemon: .running(status: "running session=active version=0.6.0+12")))

    #expect(text.contains("- CLI version: 0.6.0+12"))
    #expect(text.contains("- macOS: Version 26.0 (Build 25A1)"))
    #expect(text.contains("- Architecture: arm64"))
    #expect(text.contains("only the version of the `defi` that ran `defi triage`"))
    #expect(text.contains("Running. `defi status` printed:"))
    #expect(text.contains("running session=active version=0.6.0+12"))
    #expect(text.contains("- Config: `/Users/me/.config/defi/config.toml`"))
  }

  @Test
  func rendersContextForAStoppedDaemon() {
    let text = renderTriageContext(context(daemon: .stopped(reason: "connect failed: 2")))

    #expect(text.contains("Not running or not reachable: connect failed: 2"))
    #expect(!text.contains("`defi status` printed"))
  }

  @Test
  func promptPointsAtContextThenCarriesThePlaybook() {
    let bundled = renderTriagePrompt(contextPath: "/s/context.md", playbook: "# Playbook body")
    #expect(bundled.contains("`/s/context.md`"))
    #expect(bundled.hasSuffix("# Playbook body\n"))

    let remote = renderTriagePrompt(contextPath: "/s/context.md", playbook: nil)
    #expect(remote.contains(Triage.playbookURL))
  }

  private func context(daemon: DaemonState) -> TriageContext {
    TriageContext(
      generatedAt: Date(timeIntervalSince1970: 0),
      cliVersion: "0.6.0+12",
      cliPath: "/Applications/Defi.app/Contents/MacOS/defi",
      daemon: daemon,
      macOS: "Version 26.0 (Build 25A1)",
      architecture: "arm64",
      paths: [("Config", "/Users/me/.config/defi/config.toml")])
  }
}
