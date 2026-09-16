import Foundation

public let acceleratorKeyCodes: [String: UInt16] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5,
  "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
  "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
  "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
  "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28, "0": 29,
  "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33,
  "i": 34, "p": 35, "l": 37, "j": 38, "quote": 39,
  "k": 40, "semicolon": 41, "backslash": 42, "comma": 43,
  "slash": 44, "n": 45, "m": 46, "period": 47,
  "left": 123, "right": 124, "down": 125, "up": 126,
]

/// Shared by default merging and native hotkey parsing so aliases collide consistently.
public func normalizedAccelerator(_ accelerator: String, aliases: [String: String]) -> String? {
  var parts = accelerator.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
  guard parts.count > 1, !parts.contains(where: \.isEmpty),
    let key = parts.popLast(), acceleratorKeyCodes[key] != nil
  else { return nil }
  let modifiers = parts.flatMap { part in
    (aliases[part] ?? part).lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
      let name = $0.trimmingCharacters(in: .whitespaces)
      return switch name {
      case "command": "cmd"
      case "option": "alt"
      case "control": "ctrl"
      default: name
      }
    }
  }
  guard modifiers.allSatisfy({ ["cmd", "alt", "ctrl", "shift"].contains($0) }) else { return nil }
  return (Set(modifiers).sorted() + [key]).joined(separator: "-")
}

func mergingKeyBindings(
  _ defaults: [String: String], overrides: [String: String], aliases: [String: String]
) -> [String: String] {
  var bindings: [String: (String, String)] = [:]
  for layer in [defaults, overrides] {
    for (accelerator, command) in layer.sorted(by: { $0.key < $1.key }) {
      // Keep malformed entries intact so validation rejects them instead of
      // letting normalization overwrite a valid default.
      bindings[normalizedAccelerator(accelerator, aliases: aliases) ?? accelerator] = (accelerator, command)
    }
  }
  return Dictionary(uniqueKeysWithValues: bindings.values)
}
