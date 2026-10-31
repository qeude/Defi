import AppKit
import ApplicationServices
import Carbon
import DefiConfig
import Testing
@testable import DefiMacOS

// Real installed layouts keep the expectations honest: nothing here is a fixture that could
// drift from what macOS types. Chords are `modifiers-keycode`, written out by hand.
private let ansi: UInt32 = 91
private let jis: UInt32 = 201

@MainActor
private func installed(_ name: String, type: UInt32 = ansi) throws -> KeyboardLayout {
  try #require(keyboardLayout(inputSourceID: "com.apple.keylayout." + name, keyboardType: type))
}

private func chord(_ key: Key) -> String {
  let flags = CGEventFlags(rawValue: key.modifierBits)
  let names = [("ctrl", CGEventFlags.maskControl), ("alt", .maskAlternate), ("shift", .maskShift), ("cmd", .maskCommand)]
    .filter { flags.contains($0.1) }.map(\.0)
  return (names + [String(key.code)]).joined(separator: "-")
}

private func resolution(_ config: Config = Config(), _ layout: KeyboardLayout?) throws -> HotKeyResolution {
  try resolveHotKeys(config.keys, aliases: config.modifierCombinations, layout: layout)
}

/// Accelerator to chord, `inactive` when the binding holds none.
private func chords(_ config: Config = Config(), _ layout: KeyboardLayout?) throws -> [String: String] {
  let result = try resolution(config, layout)
  var chords = Dictionary(uniqueKeysWithValues: result.keys.map { ($0.value.accelerator, chord($0.key)) })
  for accelerator in result.inactive.keys { chords[accelerator] = "inactive" }
  return chords
}

private typealias Row = (accelerator: String, us: String, french: String, dvorak: String, jis: String)

// Mac French cannot type the bracket pair or `\` without Option-Shift, so those fall back.
private let defaultRows: [Row] = [
  ("ctrl-alt-f", "ctrl-alt-3", "ctrl-alt-3", "ctrl-alt-16", "ctrl-alt-3"),
  ("ctrl-alt-j", "ctrl-alt-38", "ctrl-alt-38", "ctrl-alt-8", "ctrl-alt-38"),
  ("ctrl-alt-k", "ctrl-alt-40", "ctrl-alt-40", "ctrl-alt-9", "ctrl-alt-40"),
  ("ctrl-alt-o", "ctrl-alt-31", "ctrl-alt-31", "ctrl-alt-1", "ctrl-alt-31"),
  ("ctrl-alt-r", "ctrl-alt-15", "ctrl-alt-15", "ctrl-alt-31", "ctrl-alt-15"),
  ("ctrl-alt-leftbracket", "ctrl-alt-33", "ctrl-alt-33", "ctrl-alt-27", "ctrl-alt-30"),
  ("ctrl-alt-rightbracket", "ctrl-alt-30", "ctrl-alt-shift-27", "ctrl-alt-24", "ctrl-alt-42"),
  ("ctrl-alt-shift-leftbracket", "ctrl-alt-shift-33", "ctrl-alt-shift-33", "ctrl-alt-shift-27", "ctrl-alt-shift-30"),
  ("ctrl-alt-shift-rightbracket", "ctrl-alt-shift-30", "ctrl-alt-shift-30", "ctrl-alt-shift-24", "ctrl-alt-shift-42"),
  ("ctrl-alt-backslash", "ctrl-alt-42", "ctrl-alt-shift-47", "ctrl-alt-42", "ctrl-alt-93"),
  ("ctrl-alt-shift-backslash", "ctrl-alt-shift-42", "ctrl-alt-shift-42", "ctrl-alt-shift-42", "ctrl-alt-shift-93"),
  ("ctrl-alt-minus", "ctrl-alt-27", "ctrl-alt-24", "ctrl-alt-39", "ctrl-alt-27"),
  ("ctrl-alt-equal", "ctrl-alt-24", "ctrl-alt-44", "ctrl-alt-30", "ctrl-alt-shift-27"),
  ("ctrl-alt-comma", "ctrl-alt-43", "ctrl-alt-46", "ctrl-alt-13", "ctrl-alt-43"),
  ("ctrl-alt-period", "ctrl-alt-47", "ctrl-alt-shift-43", "ctrl-alt-14", "ctrl-alt-47"),
  ("ctrl-alt-semicolon", "ctrl-alt-41", "ctrl-alt-43", "ctrl-alt-6", "ctrl-alt-41"),
  ("ctrl-alt-quote", "ctrl-alt-39", "ctrl-alt-39", "ctrl-alt-12", "ctrl-alt-39"),
  // Digits and arrows never follow the layout.
  ("ctrl-alt-1", "ctrl-alt-18", "ctrl-alt-18", "ctrl-alt-18", "ctrl-alt-18"),
  ("ctrl-alt-shift-9", "ctrl-alt-shift-25", "ctrl-alt-shift-25", "ctrl-alt-shift-25", "ctrl-alt-shift-25"),
  ("ctrl-alt-left", "ctrl-alt-123", "ctrl-alt-123", "ctrl-alt-123", "ctrl-alt-123"),
]

@MainActor
struct KeyboardLayoutResolverTests {
  @Test
  func usAndUsInternationalKeepEveryDefaultOnItsPhysicalKey() throws {
    let physical = try configuredHotKeys(Config()).mapValues(\.command)
    for name in ["US", "USInternational-PC"] {
      let resolved = try configuredHotKeys(Config(), layout: installed(name)).mapValues(\.command)
      #expect(resolved == physical, "\(name)")
    }
  }

  @Test(arguments: ["US", "French", "Dvorak"])
  func defaultsLandOnTheKeysTheLayoutPrints(name: String) throws {
    let result = try chords(Config(), installed(name))
    for row in defaultRows {
      let expected = name == "US" ? row.us : name == "French" ? row.french : row.dvorak
      #expect(result[row.accelerator] == expected, "\(name) \(row.accelerator)")
    }
  }

  @Test
  func japaneseKeyboardUsesTheKeysItPrints() throws {
    #expect(KBGetLayoutType(Int16(jis)) == OSType(kKeyboardJIS))
    let result = try chords(Config(), installed("ABC", type: jis))
    for row in defaultRows { #expect(result[row.accelerator] == row.jis, "JIS \(row.accelerator)") }
  }

  @Test
  func nilLayoutIsTheTodayTable() throws {
    let names = Array(acceleratorKeyCodes.keys)
    let keys = Dictionary(uniqueKeysWithValues: names.map { ("ctrl-alt-shift-" + $0, "diagnostic-mark") })
    let result = try resolveHotKeys(keys, aliases: [:], layout: nil)
    #expect(result.inactive.isEmpty)
    for name in names {
      let code = try #require(acceleratorKeyCodes[name])
      #expect(result.keys.contains { chord($0.key) == "ctrl-alt-shift-\(code)" && $0.value.accelerator == "ctrl-alt-shift-" + name }, "\(name)")
    }
  }

  // Hand-derived from `com.apple.keylayout.German`: `\` needs Option-Shift-7, which is
  // ctrl-alt-shift-7, and Shift-# is claimed by `'`. Key code 0 is the lowest free key.
  @Test
  func germanBackslashPairClaimsTheLowestFreeKey() throws {
    let result = try chords(Config(), installed("German"))
    #expect(result["ctrl-alt-shift-backslash"] == "ctrl-alt-shift-0")
    #expect(result["ctrl-alt-backslash"] == "ctrl-alt-42")
  }

  @Test(arguments: ["Spanish", "Swedish"])
  func backslashFallsBackToTheLowestFreeKey(name: String) throws {
    #expect(try chords(Config(), installed(name))["ctrl-alt-backslash"] == "ctrl-alt-0")
  }

  @Test
  func everyDefaultResolvesOnEveryInstalledAsciiLayout() throws {
    let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    var read = 0
    for source in sources {
      guard let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable),
        CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(ascii).takeUnretainedValue()),
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
        let layout = keyboardLayout(
          inputSourceID: Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String, keyboardType: ansi)
      else { continue }
      read += 1
      let result = try resolution(Config(), layout)
      #expect(result.inactive.count == 0, "\(result.inactive)")
      #expect(result.keys.count == Config().keys.count)
    }
    #expect(read > 20)
  }

  @Test
  func lettersFollowTheLayoutAndFallBackToTheirOwnKey() throws {
    // Without an `o` on the base layer, the table name keeps its physical key.
    let withoutO = KeyboardLayout(characters: [[]: [3: "f", 31: "x"]])
    let result = try chords(Config(), withoutO)
    #expect(result["ctrl-alt-f"] == "ctrl-alt-3")
    #expect(result["ctrl-alt-o"] == "ctrl-alt-31")
    let onlyUpper = KeyboardLayout(characters: [[]: [:], .shift: [5: "o"]])
    #expect(try chords(Config(), onlyUpper)["ctrl-alt-o"] == "ctrl-alt-31")
  }

  @Test
  func commandChordsReadTheCommandLayer() throws {
    let layout = try installed("DVORAK-QWERTYCMD")
    let config = Config(keys: ["ctrl-alt-cmd-f": "maximize-column"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-f"] == "ctrl-alt-16")
    #expect(result["ctrl-alt-cmd-f"] == "ctrl-alt-cmd-3")
  }

  @Test
  func keypadCodesAreNeverScanned() throws {
    let config = Config(keys: ["alt-slash": "maximize-column"])
    #expect(try chords(config, installed("French"))["alt-slash"] == "alt-shift-47")
  }

  @Test
  func literalsOnFrench() throws {
    let config = Config(keys: ["alt-é": "maximize-column", "ctrl-alt-é": "toggle-floating", "ctrl-alt-ù": "toggle-floating"])
    let french = try installed("French")
    let result = try resolution(config, french)
    let byAccelerator = Dictionary(uniqueKeysWithValues: result.keys.map { ($0.value.accelerator, chord($0.key)) })
    #expect(byAccelerator["alt-é"] == "alt-19")
    #expect(byAccelerator["ctrl-alt-ù"] == "ctrl-alt-39")
    // The digit row wins: workspace 2 already holds ctrl-alt-19.
    #expect(result.inactive["ctrl-alt-é"] == .held(by: "ctrl-alt-2"))
    // The literal took quote's physical key, so quote claims the lowest free one instead.
    #expect(byAccelerator["ctrl-alt-quote"] == "ctrl-alt-0")
  }

  @Test
  func literalsOnJapaneseKeyboard() throws {
    let layout = try installed("ABC", type: jis)
    let config = Config(keys: ["ctrl-alt-¥": "maximize-column", "ctrl-alt-_": "toggle-floating"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-¥"] == "ctrl-alt-93")
    #expect(result["ctrl-alt-_"] == "ctrl-alt-94")
    // ¥ took the key backslash would use, and `]` took its physical key.
    #expect(result["ctrl-alt-backslash"] == "ctrl-alt-0")
  }

  @Test
  func literalsOnUs() throws {
    let config = Config(keys: ["ctrl-alt-_": "maximize-column", "ctrl-alt-é": "toggle-floating"])
    let result = try resolution(config, installed("US"))
    #expect(result.keys.contains { $0.value.accelerator == "ctrl-alt-_" && chord($0.key) == "ctrl-alt-shift-27" })
    #expect(result.inactive == ["ctrl-alt-é": .absentFromLayout])
  }

  @Test
  func aCharacterBindingBeatsAPositionalOneOnTheSameChord() throws {
    // `m` printed on the semicolon key: the letter keeps it, semicolon looks elsewhere.
    let layout = KeyboardLayout(characters: [[]: [41: "m"]])
    let config = Config(keys: ["ctrl-alt-m": "maximize-column", "ctrl-alt-semicolon": "join-window left"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-m"] == "ctrl-alt-41")
    #expect(result["ctrl-alt-semicolon"] == "ctrl-alt-0")
  }

  @Test
  func aFallbackNeverTakesAChordAnotherCharacterNeeds() throws {
    // `quote` sorts before `semicolon`, but its physical fallback (39) is where `;` is printed.
    let layout = KeyboardLayout(characters: [[]: [39: ";"]])
    let config = Config(keys: ["ctrl-alt-quote": "join-window right", "ctrl-alt-semicolon": "join-window left"])
    let result = try chords(config, layout)
    #expect(result["ctrl-alt-semicolon"] == "ctrl-alt-39")
    #expect(result["ctrl-alt-quote"] == "ctrl-alt-0")
  }

  @Test
  func bracketPairSplitsDeterministicallyOnFrench() throws {
    // Both brackets want ctrl-alt-shift-5; the plainer written chord wins it every time.
    let french = try installed("French")
    for _ in 0..<3 {
      let result = try chords(Config(), french)
      #expect(result["ctrl-alt-rightbracket"] == "ctrl-alt-shift-27")
      #expect(result["ctrl-alt-shift-rightbracket"] == "ctrl-alt-shift-30")
    }
  }

  @Test
  func unknownLiteralsAreInactiveOnlyForThatBinding() throws {
    let config = Config(keys: ["ctrl-alt-ж": "maximize-column"])
    let result = try resolution(config, installed("US"))
    #expect(result.inactive == ["ctrl-alt-ж": .absentFromLayout])
    #expect(result.keys.count == Config().keys.count)
  }

  @Test
  func malformedAcceleratorsStillFail() {
    #expect(throws: HotKeyError.invalidAccelerator("ctrl-alt-unknown")) {
      try resolveHotKeys(["ctrl-alt-unknown": "maximize-column"], aliases: [:], layout: nil)
    }
  }
}

@MainActor
struct KeyboardLayoutLabelTests {
  private func label(_ accelerator: String, _ layout: KeyboardLayout, _ config: Config = Config()) -> String {
    shortcutKeyLabel(
      accelerator, aliases: [:], resolved: ShortcutResolution(config: config, layout: layout))
  }

  @Test
  func labelsNameTheKeyActuallyPressed() throws {
    let french = try installed("French")
    #expect(label("ctrl-alt-period", french) == "⌃⌥⇧;")
    #expect(label("ctrl-alt-rightbracket", french) == "⌃⌥⇧)")
    #expect(label("ctrl-alt-leftbracket", french) == "⌃⌥^")
    #expect(label("ctrl-alt-1", french) == "⌃⌥1")
    #expect(label("ctrl-alt-backslash", try installed("ABC", type: jis)) == "⌃⌥¥")
  }

  @Test
  func inactiveShortcutsSayWhy() throws {
    let config = Config(keys: ["ctrl-alt-é": "maximize-column"])
    #expect(label("ctrl-alt-é", try installed("French"), config) == "Held by ⌃⌥2")
    #expect(label("ctrl-alt-é", try installed("US"), config) == "Not on this layout")
  }

  @Test
  func anUnsavedAcceleratorIsLabelledFromItsOwnResolution() throws {
    #expect(label("ctrl-alt-ù", try installed("French")) == "⌃⌥Ù")
  }

  @Test
  func cheatsheetShowsTheResolvedKeys() throws {
    let rows = shortcutGroups(config: Config(), layout: try installed("French")).flatMap(\.rows)
    #expect(rows.contains { $0.action == "Last column" && $0.modifiers == "⌃⌥⇧" && $0.key == ")" })
    #expect(rows.contains { $0.action == "Workspace 1–9" && $0.key == "1–9" })
  }

  @Test(arguments: ["US", "French", "Dvorak", "ABC"])
  func recordedKeysResolveBackToTheKeyPressed(name: String) throws {
    let layout = try installed(name, type: name == "ABC" ? jis : ansi)
    let modifiers: NSEvent.ModifierFlags = [.control, .option]
    for code in layoutScannedKeyCodes {
      guard let accelerator = recordedAccelerator(keyCode: code, modifiers: modifiers, layout: layout) else {
        // Only a key with no table name may stay unrecorded, e.g. French 93 printing a character that
        // an earlier key already prints.
        #expect(!acceleratorKeyCodes.values.contains(code), "\(name) \(code)")
        continue
      }
      let resolved = try resolveHotKeys([accelerator: ""], aliases: [:], layout: layout)
      #expect(resolved.keys.keys.map(chord) == ["ctrl-alt-\(code)"], "\(name) \(code) \(accelerator)")
    }
  }

  @Test
  func recordedNamesOnFrench() throws {
    let french = try installed("French")
    let modifiers: NSEvent.ModifierFlags = [.control, .option]
    #expect(recordedAccelerator(keyCode: 33, modifiers: modifiers, layout: french) == "alt-ctrl-^")
    #expect(recordedAccelerator(keyCode: 18, modifiers: modifiers, layout: french) == "alt-ctrl-1")
    #expect(recordedAccelerator(keyCode: 41, modifiers: modifiers, layout: french) == "alt-ctrl-m")
  }
}
