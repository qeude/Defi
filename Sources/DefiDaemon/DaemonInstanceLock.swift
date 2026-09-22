import Darwin
import DefiIPC
import Foundation

final class DaemonInstanceLock {
  private let descriptor: Int32

  init(url: URL = DaemonLockPath.defaultURL) throws {
    let descriptor = Darwin.open(
      url.path,
      O_CREAT | O_RDWR,
      mode_t(S_IRUSR | S_IWUSR)
    )
    guard descriptor >= 0 else {
      throw DaemonInstanceLockError.systemCall("open", errno)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      if code == EWOULDBLOCK {
        throw DaemonInstanceLockError.alreadyRunning
      }
      throw DaemonInstanceLockError.systemCall("flock", code)
    }
    // Acquire ownership only after success; a throwing initialized class runs
    // deinit and would otherwise close the failed descriptor a second time.
    self.descriptor = descriptor
  }

  deinit {
    flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }
}

enum DaemonInstanceLockError: Error, Equatable, CustomStringConvertible {
  case alreadyRunning
  case systemCall(String, Int32)

  var description: String {
    switch self {
    case .alreadyRunning:
      "Defi is already running"
    case let .systemCall(name, code):
      "\(name) failed: \(String(cString: strerror(code)))"
    }
  }
}
