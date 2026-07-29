import DefiIPC
import Foundation

@main
struct DefiCLI {
  static func main() {
    do {
      let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
      if let service = options.service {
        try ServiceManager.run(service)
        return
      }
      guard !options.command.isEmpty else {
        print(Options.usage)
        exit(2)
      }
      let response = try sendCommand(
        options.command.joined(separator: " "),
        to: options.socketURL
      )
      let stream = response.ok ? FileHandle.standardOutput : FileHandle.standardError
      stream.write(Data("\(response.message)\n".utf8))
      if !response.ok { exit(1) }
    } catch {
      FileHandle.standardError.write(Data("defi: \(error)\n".utf8))
      exit(1)
    }
  }
}

private struct Options {
  static let usage = """
    usage:
      defi [--socket <path>] <command> [arguments]
      defi service install|start|stop|restart|status|uninstall

    examples:
      defi focus-column left
      defi workspace 2
      defi status
      defi trace
    """

  let socketURL: URL
  let command: [String]
  let service: String?

  init(arguments: [String]) throws {
    var socketURL = SocketPath.defaultURL
    var remaining: [String] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == "--socket" {
        index += 1
        guard arguments.indices.contains(index) else { throw CLIError.usage }
        socketURL = URL(filePath: arguments[index])
      } else {
        remaining.append(arguments[index])
      }
      index += 1
    }
    if remaining.first == "service" {
      guard remaining.count == 2 else { throw CLIError.usage }
      service = remaining[1]
      command = []
    } else {
      service = nil
      command = remaining
    }
    self.socketURL = socketURL
  }
}

private enum CLIError: Error, CustomStringConvertible {
  case usage

  var description: String { Options.usage }
}
