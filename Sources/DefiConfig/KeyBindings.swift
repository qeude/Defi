import Foundation

/// Shared by default merging and native hotkey parsing so aliases collide consistently.
public func normalizedAccelerator(_ accelerator: String, aliases: [String: String]) -> String? {
  var parts = accelerator.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
  guard !parts.contains(where: \.isEmpty), let key = parts.popLast() else { return nil }
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
  guard !modifiers.contains(where: { $0.isEmpty || $0.contains("-") }) else { return nil }
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
