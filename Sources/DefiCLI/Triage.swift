import DefiIPC
import Foundation

enum TriageAgent: String, CaseIterable {
  case claude
  case codex
}

enum TriageAgentChoice: Equatable {
  case use(TriageAgent)
  case ask([TriageAgent])
  case noneInstalled
  case requestedMissing(TriageAgent)
  case needsTerminal
}

enum DaemonState: Equatable {
  case running(status: String)
  case stopped(reason: String)
}

struct TriageContext {
  let generatedAt: Date
  let cliVersion: String
  let cliPath: String
  let daemon: DaemonState
  let macOS: String
  let architecture: String
  let paths: [(label: String, path: String)]
}

enum TriageError: Error, CustomStringConvertible {
  case requestedAgentMissing(TriageAgent)
  case choiceNeedsTerminal
  case noChoiceMade
  case setupFailed(String)
  case execFailed(agent: String, errno: Int32, promptPath: String)

  var description: String {
    switch self {
    case let .requestedAgentMissing(agent):
      "\(agent.rawValue) was not found on PATH"
    case .choiceNeedsTerminal:
      "claude and codex are both installed; pass --agent claude or --agent codex"
    case .noChoiceMade:
      "no agent chosen"
    case let .setupFailed(detail):
      detail
    case let .execFailed(agent, code, promptPath):
      "could not start \(agent): \(String(cString: strerror(code))) (errno \(code)); the prompt is at \(promptPath)"
    }
  }
}

func selectTriageAgent(
  requested: TriageAgent?,
  installed: [TriageAgent],
  isInteractive: Bool
) -> TriageAgentChoice {
  if let requested {
    return installed.contains(requested) ? .use(requested) : .requestedMissing(requested)
  }
  switch installed.count {
  case 0: return .noneInstalled
  case 1: return .use(installed[0])
  default: return isInteractive ? .ask(installed) : .needsTerminal
  }
}

func renderTriageContext(_ context: TriageContext) -> String {
  let daemon: String
  switch context.daemon {
  case let .running(status):
    daemon = """
      Running. `defi status` printed:

      ```
      \(status)
      ```
      """
  case let .stopped(reason):
    daemon = "Not running or not reachable: \(reason)"
  }
  let paths = context.paths.map { "- \($0.label): `\($0.path)`" }.joined(separator: "\n")
  return """
    # Defi triage context

    Generated \(ISO8601DateFormatter().string(from: context.generatedAt)) by `defi triage`.

    ## Machine

    - CLI version: \(context.cliVersion)
    - CLI path: `\(context.cliPath)`
    - macOS: \(context.macOS)
    - Architecture: \(context.architecture)

    The CLI version is only the version of the `defi` that ran `defi triage`. The
    daemon may run another build. A daemon that reports `version=` in its status
    shows it there; older daemons do not report it.

    ## Daemon

    \(daemon)

    ## Paths

    \(paths)

    """
}

func renderTriagePrompt(contextPath: String, playbook: String?) -> String {
  let body =
    playbook
    ?? """
      The playbook is not bundled with this build. Fetch
      \(Triage.playbookURL)
      and follow it exactly. If you cannot fetch it, say so and ask the user to
      paste it.
      """
  return """
    # Defi triage

    Machine facts are in `\(contextPath)`. Read that file first.

    ---

    \(body)

    """
}

enum Triage {
  static let playbookURL = "https://raw.githubusercontent.com/qeude/Defi/main/.github/triage/PLAYBOOK.md"

  static func run(agent requested: TriageAgent?, socketURL: URL) throws {
    let installed = TriageAgent.allCases.filter {
      executablePath(named: $0.rawValue, searching: ProcessInfo.processInfo.environment["PATH"]) != nil
    }
    let agent: TriageAgent?
    switch selectTriageAgent(
      requested: requested, installed: installed,
      isInteractive: isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0)
    {
    case let .use(chosen): agent = chosen
    case let .ask(choices): agent = try prompt(among: choices)
    case .noneInstalled: agent = nil
    case let .requestedMissing(missing): throw TriageError.requestedAgentMissing(missing)
    case .needsTerminal: throw TriageError.choiceNeedsTerminal
    }

    let now = Date()
    let home = FileManager.default.homeDirectoryForCurrentUser
    let appURL = Bundle.main.executableURL.flatMap(appBundleURL(from:))
    let session = home
      .appending(path: "Library/Application Support/Defi/triage")
      .appending(
        path: ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-"),
        directoryHint: .isDirectory)
    let contextURL = session.appending(path: "context.md")
    let promptURL = session.appending(path: "prompt.md")

    let context = TriageContext(
      generatedAt: now,
      cliVersion: appURL.flatMap(Bundle.init(url:)).map(versionString) ?? "development",
      cliPath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0],
      daemon: daemonState(socketURL: socketURL),
      macOS: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architecture,
      paths: [
        ("Config", home.appending(path: ".config/defi/config.toml").path),
        ("Diagnostics", home.appending(path: "Library/Logs/Defi/Diagnostics").path),
        ("Source cache", home.appending(path: "Library/Caches/Defi/triage-source").path),
        ("Crash reports", home.appending(path: "Library/Logs/DiagnosticReports").path),
      ])
    let playbook = appURL.flatMap {
      try? String(
        contentsOf: $0.appending(path: "Contents/Resources/triage-playbook.md"), encoding: .utf8)
    }

    do {
      try FileManager.default.createDirectory(
        at: session, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try renderTriageContext(context).write(to: contextURL, atomically: true, encoding: .utf8)
      try renderTriagePrompt(contextPath: contextURL.path, playbook: playbook)
        .write(to: promptURL, atomically: true, encoding: .utf8)
    } catch {
      throw TriageError.setupFailed("could not write \(session.path): \(error.localizedDescription)")
    }

    guard let agent else {
      print("No coding agent (claude or codex) found on PATH.")
      print("Context: \(contextURL.path)")
      print("Prompt: \(promptURL.path)")
      print("Paste the prompt into any coding agent to start the triage.")
      return
    }
    print("Starting \(agent.rawValue) in \(session.path)")
    fflush(stdout)
    guard chdir(session.path) == 0 else {
      throw TriageError.setupFailed(
        "could not enter \(session.path): \(String(cString: strerror(errno)))")
    }
    // The playbook runs `defi`, which a manual install does not link onto PATH.
    if let directory = Bundle.main.executableURL?.deletingLastPathComponent().path {
      setenv("PATH", "\(directory):\(ProcessInfo.processInfo.environment["PATH"] ?? "")", 1)
    }
    let message =
      "Read the file \"\(promptURL.path)\" and follow its instructions exactly: it is your Defi triage playbook, and it starts with asking the user what went wrong."
    var arguments: [UnsafeMutablePointer<CChar>?] = [strdup(agent.rawValue), strdup(message), nil]
    execvp(agent.rawValue, &arguments)
    throw TriageError.execFailed(agent: agent.rawValue, errno: errno, promptPath: promptURL.path)
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unknown"
    #endif
  }

  private static func versionString(of bundle: Bundle) -> String {
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    guard let version else { return "development" }
    return build.map { "\(version)+\($0)" } ?? version
  }

  private static func daemonState(socketURL: URL) -> DaemonState {
    do {
      let response = try sendCommand("status", to: socketURL)
      return response.ok
        ? .running(status: response.message) : .stopped(reason: "status failed: \(response.message)")
    } catch {
      return .stopped(reason: "\(error)")
    }
  }

  private static func executablePath(named name: String, searching path: String?) -> String? {
    (path ?? "").split(separator: ":")
      .map { "\($0)/\(name)" }
      .first { access($0, X_OK) == 0 }
  }

  private static func prompt(among choices: [TriageAgent]) throws -> TriageAgent {
    print("Choose a coding agent:")
    for (offset, choice) in choices.enumerated() { print("  \(offset + 1)) \(choice.rawValue)") }
    while true {
      print("Agent [1-\(choices.count)]: ", terminator: "")
      fflush(stdout)
      guard let line = readLine() else { throw TriageError.noChoiceMade }
      let answer = line.trimmingCharacters(in: .whitespaces)
      if let number = Int(answer), choices.indices.contains(number - 1) { return choices[number - 1] }
      if let named = choices.first(where: { $0.rawValue == answer }) { return named }
    }
  }
}
