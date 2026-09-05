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
      if options.purge {
        try Uninstaller.purge()
        return
      }
      guard !options.command.isEmpty else {
        print(Options.usage)
        exit(2)
      }
      let response = try sendCommand(
        options.command.joined(separator: " "),
        monitorIndex: options.monitorIndex,
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

struct Options {
  static let usage = """
    usage:
      defi [--socket <path>] [--monitor <index>] <command> [arguments]
      defi service enable|disable|start|stop|restart|status
      defi uninstall --purge

    examples:
      defi focus-column left
      defi workspace 2
      defi --monitor 2 workspace web
      defi list-workspaces --json
      defi --monitor 1 set-reserved-area top 36
      defi status
      defi trace
    """

  let socketURL: URL
  let monitorIndex: Int?
  let command: [String]
  let service: String?
  let purge: Bool

  init(arguments: [String]) throws {
    var socketURL = SocketPath.defaultURL
    var monitorIndex: Int?
    var remaining: [String] = []
    var index = 0
    while index < arguments.count {
      if arguments[index] == "--socket" {
        index += 1
        guard arguments.indices.contains(index) else { throw CLIError.usage }
        socketURL = URL(filePath: arguments[index])
      } else if arguments[index] == "--monitor" {
        index += 1
        guard arguments.indices.contains(index),
          let parsed = Int(arguments[index]), parsed > 0
        else {
          throw CLIError.usage
        }
        monitorIndex = parsed
      } else {
        remaining.append(arguments[index])
      }
      index += 1
    }
    if remaining == ["uninstall", "--purge"] {
      purge = true
      service = nil
      command = []
    } else if remaining.first == "service" {
      guard remaining.count == 2 else { throw CLIError.usage }
      purge = false
      service = remaining[1]
      command = []
    } else {
      purge = false
      service = nil
      command = remaining
    }
    self.socketURL = socketURL
    self.monitorIndex = monitorIndex
  }
}

enum CLIError: Error, Equatable, CustomStringConvertible {
  case usage

  var description: String { Options.usage }
}
