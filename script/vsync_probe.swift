import AppKit
import QuartzCore

// Independent display-link witness for script/tear_probe.py. A pulse gap here means the
// display (WindowServer) stopped presenting; a gap only in Defi's trace means Defi's
// main thread stalled. Prints {"gap":<uptime of resumed pulse>,"ms":<gap>} for gaps > 30 ms.
//   vsync-probe <seconds>

final class Witness: NSObject {
  var last = -Double.infinity
  @objc func pulse(_ link: CADisplayLink) {
    let now = ProcessInfo.processInfo.systemUptime
    if last.isFinite, now - last > 0.030 {
      print(String(format: "{\"gap\":%.6f,\"ms\":%.1f}", now, (now - last) * 1000))
      fflush(stdout)
    }
    last = now
  }
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 60 : 60
let witness = Witness()
guard let screen = NSScreen.main else { exit(1) }
let link = screen.displayLink(target: witness, selector: #selector(Witness.pulse(_:)))
link.add(to: .main, forMode: .common)
signal(SIGTERM) { _ in exit(0) }
print(String(format: "{\"start\":%.6f}", ProcessInfo.processInfo.systemUptime))
fflush(stdout)
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
