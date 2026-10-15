import Foundation

// cpu-load <threads>: spins that many userInitiated threads until stdin closes, so the
// load ends with its parent even when the parent is killed.
guard CommandLine.arguments.count == 2, let count = Int(CommandLine.arguments[1]), count > 0 else {
  FileHandle.standardError.write(Data("usage: cpu-load <threads>\n".utf8))
  exit(2)
}
for _ in 0..<count {
  let thread = Thread {
    var value: UInt64 = 0
    while true { value = value &* 6_364_136_223_846_793_005 &+ 1 }
  }
  thread.qualityOfService = .userInitiated
  thread.start()
}
while readLine() != nil {}
exit(0)
